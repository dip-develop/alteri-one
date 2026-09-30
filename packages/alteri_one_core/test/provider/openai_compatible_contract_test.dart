// The contract of the OpenAI-compatible provider. Task 0.13.
//
// What this file is: the mechanical half of "a `package:http`-compatible transport, streaming,
// usage and a capability probe for tools, streaming, JSON mode and context window. The
// capability matrix is checked before start, and chunk assembly follows providers.md §3.2"
// — `docs/process/task-breakdown.md` §`0.13`.
//
// The greppable acceptance string for the task is the description of the first test below:
// "OpenAI-compatible provider streams usage and probes capabilities".
//
// ## What this file asserts that a "no errors" check would not
//
// Almost nothing here is a presence check. A provider that returned one result chunk and never
// threw would satisfy `expect(chunks.last, isA<AlteriOneChatResult>())` on the happy path, so
// the file is built out of the *failures* §3.2 names, each of which is reachable and each of
// which is asserted with its **code**:
//
// - a tool call whose argument JSON never parses is `-32602` naming the tool, and never an empty
//   object — with a positive control that the same tool *does* parse when its fragments are
//   complete;
// - a stream that ends with a `finish_reason` and no `usage` is `-32603`, which is the check
//   that `stream_options.include_usage` in the request body exists to make falsifiable;
// - a `finish_reason: length` is `-32030` and not a finish, because a truncated reply shown as a
//   complete one is the failure the code exists for;
// - a missing capability in the profile's `requires` is `provider.incompatible_capabilities`
//   **before any request is made**, asserted by counting the requests the double received — the
//   acceptance criterion's "explicit refusal on a missing capability";
// - §3.2's ordering rule is asserted *against* a stream whose fragments arrive out of index
//   order, because an in-order fixture proves nothing about a rule that is about order.
//
// ## The two framing traps are asserted directly
//
// `sse.dart` documents a CRLF block terminator producing two trailing empty elements rather than
// one, and a chunk boundary inside a multi-byte character. Both have bitten a framing
// implementation in this repository already, and both are cheap to state here and impossible to
// state anywhere else: a `dart test` body stream is delivered in whatever pieces the double
// chooses, which is exactly the freedom a real endpoint's `dart:io` chunking does not give you.
//
// ## Why the internals are imported by path
//
// The wire, the SSE reader and the assembler are deliberately **not** exported from
// `package:alteri_one_core/provider.dart` — a test that drove them directly would be a test of a
// private arrangement. Three things are reached here and the reason is given at the point of
// reach: `SseReader` and `assembledCall` have rules that cannot be observed from outside (a
// reader is fed text, a call is a pure function of four scalars) and each rule is worth one
// test of its own rather than one large test through the provider that happens to cover it.
// `OpenAiCompatibleProvider.maxSseLineBytes` is the third: a test that grew its own over-long
// line would be exercising a bound it chose rather than the bound the provider imposes — and the
// class *is* exported, so reaching for a member of it is not reaching past the surface.
//
// ## No `package:http`, and no real endpoint
//
// The double is an `HttpClientPort`, so the whole file is offline and deterministic: the
// blocking chain must not reach the network (`testing-strategy.md` §4) and §2.1 requires startup
// not to perform network I/O. A real endpoint would also make §3.2's misaligned-chunk case
// untestable, which is why task `0.21` builds a fixture server and why this one does not need
// to.
//
// A parse of `docs/architecture/providers.md` §3.2's *own text* is used in one test, so that a
// change to the specification and a change to the code cannot agree by accident — the
// arrangement the registry's contract test uses for `overview.md` §5.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;

import 'package:alteri_one_core/core.dart' show toolIdGrammar;
import 'package:alteri_one_core/profile.dart'
    show
        ConfigDiagnostic,
        ModelFeature,
        ProviderDiagnosticCode,
        ProviderRef,
        ProfileException;
import 'package:alteri_one_core/provider.dart';
import 'package:alteri_one_platform/alteri_one_platform.dart';
import 'package:alteri_one_protocol/alteri_one_protocol.dart'
    show DomainErrorCode, JsonRpcErrorCode;
import 'package:test/test.dart';

// The two internals this file reaches past the public surface, for the reason its header gives.
import 'package:alteri_one_core/src/provider/sse.dart' show SseReader;
import 'package:alteri_one_core/src/provider/wire.dart'
    show chatCompletionsUri, eventStreamContentType, streamDoneSentinel;

void main() {
  group('the wire request', () {
    test('OpenAI-compatible provider streams usage and probes capabilities', () async {
      // The headline, and the task's greppable acceptance string. Four claims:
      //
      // - **the wire request**: the body §3.1's table describes, with the streaming and usage
      //   fields that make §4's "usage is mandatory" checkable;
      // - **streaming**: real deltas reach the caller *before* the turn ends, which is §3's
      //   reason for the interface and the thing a batch-only adapter cannot demonstrate;
      // - **usage**: normalised from the wire's own three members, cached tokens included;
      // - **probes capabilities**: `requires` is resolved before the first model turn.
      //
      // The URL is checked here too, because a provider that posts to the wrong path fails
      // every other assertion in this file identically to one that works, and the reader would
      // spend the first test of the suite finding out which it was.
      final endpoint = _Endpoint();
      endpoint.reply(
        status: 200,
        contentType: eventStreamContentType,
        frames: <String>[
          _frame(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'index': 0,
                'delta': <String, Object?>{'content': 'Hello'},
              },
            ],
          }),
          _frame(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'index': 0,
                'delta': <String, Object?>{'content': ', world'},
                'finish_reason': 'stop',
              },
            ],
          }),
          _frame(<String, Object?>{
            'choices': const <Object?>[],
            'usage': <String, Object?>{
              'prompt_tokens': 11,
              'completion_tokens': 4,
              'prompt_tokens_details': <String, Object?>{'cached_tokens': 3},
            },
          }),
          streamDoneSentinel,
        ],
      );

      final provider = _providerFor(endpoint);
      final chunks = await provider
          .chat(
            AlteriOneRequest(
              messages: AlteriOneConversation(<AlteriOneMessage>[
                AlteriOneMessage(role: AlteriOneRole.user, content: 'hello'),
              ]),
              maxOutputTokens: 64,
            ),
            model: 'test-model',
          )
          .toList();

      // **The request, exactly as it left.** One body, so the assertions are about the wire
      // rather than about the double: §3.1's mapping, §3's `stream`, and the
      // `stream_options` that makes a missing usage reportable as `-32603` instead of
      // indistinguishable from an endpoint that does not report it.
      expect(endpoint.requests, hasLength(1));
      final sent = endpoint.requests.single;
      expect(sent.method, 'POST');
      expect(sent.uri.toString(), 'http://127.0.0.1:11434/v1/chat/completions');
      expect(sent.headers['accept'], <String>[eventStreamContentType]);
      final body = _jsonBody(sent) as Map<String, Object?>;
      expect(body['model'], 'test-model');
      expect(body['stream'], isTrue);
      expect(body['max_tokens'], 64);
      expect(
        body['stream_options'],
        <String, Object?>{'include_usage': true},
        reason:
            '§3.2 makes a missing usage block -32603, which is only a check if usage was '
            'asked for',
      );
      expect(body['messages'], <Object?>[
        <String, Object?>{'role': 'user', 'content': 'hello'},
      ]);
      expect(
        body.containsKey('tools'),
        isFalse,
        reason:
            '§3.1 maps ToolDescriptor onto the wire, and ToolDescriptor arrives with the '
            'tool contract; a request carrying a probe tool would put an id in the model\'s '
            'vocabulary that no unit owns',
      );

      // **The turn.** Deltas, then the mandatory result — and the assembled text, so §3's
      // "carried alongside the deltas rather than instead of them" is checked rather than
      // assumed. The deltas are compared on their *text* because `AlteriOneTextDelta` is a
      // reporting type with no `==`: a delta is a thing that happened, not a value, and giving
      // it value equality would make two identical fragments of two different turns the same
      // object as far as a comparison was concerned.
      expect(chunks, hasLength(3));
      expect((chunks[0] as AlteriOneTextDelta).text, 'Hello');
      expect((chunks[1] as AlteriOneTextDelta).text, ', world');
      final result = chunks.last as AlteriOneChatResult;
      expect(result.finishReason, AlteriOneFinishReason.stop);
      expect(result.assembledText, 'Hello, world');
      expect(result.usage.inputTokens, 11);
      expect(result.usage.outputTokens, 4);
      expect(result.usage.cachedInputTokens, 3);
      expect(
        result.usage.totalTokens,
        15,
        reason: 'cached tokens are a subset of input, not an addition to it',
      );
    });

    test('the base URL is appended to, never resolved against', () {
      // `Uri.resolve` **replaces the base's last segment**, so
      // `Uri.parse('http://127.0.0.1:11434/v1').resolve('chat/completions')` is
      // `http://127.0.0.1:11434/chat/completions` — outside the `/v1` the profile named,
      // produced by a method whose purpose is to produce a path inside it, and looking like a
      // successful join. The same trap as `Paths.resolveBeneath` in `alteri_one_platform`, on a
      // URL instead of a path.
      expect(
        chatCompletionsUri('http://127.0.0.1:11434/v1').toString(),
        'http://127.0.0.1:11434/v1/chat/completions',
      );
      expect(
        chatCompletionsUri('http://127.0.0.1:11434/v1/').toString(),
        'http://127.0.0.1:11434/v1/chat/completions',
        reason: 'a trailing slash and no trailing slash are the same base',
      );
      expect(
        chatCompletionsUri('https://api.openai.com/v1').toString(),
        'https://api.openai.com/v1/chat/completions',
      );
      // And the scheme rule, which is `install-and-update.md` §1's egress rules having no
      // verdict on a scheme they cannot classify.
      expect(
        () => chatCompletionsUri('file:///etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => chatCompletionsUri('127.0.0.1:11434/v1'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'a tool outcome and the assistant turn that asked for it round-trip',
      () async {
        // §3.1's table in the direction the *second* turn needs. The first is the one the tests
        // above cover, and this one is the reason `AlteriOneMessage.toolCalls` exists: an
        // assistant turn that called tools cannot go back on the wire without them, and a provider
        // built without the field could not complete a second turn at all.
        final conversation = AlteriOneConversation(<AlteriOneMessage>[
          AlteriOneMessage(
            role: AlteriOneRole.user,
            content: 'read the readme',
          ),
          AlteriOneMessage(
            role: AlteriOneRole.assistant,
            content: '',
            toolCalls: const <AlteriOneToolCall>[
              AlteriOneToolCall(
                id: 'call-1',
                name: 'fs.read',
                arguments: '{"path":"README.md"}',
              ),
            ],
          ),
          AlteriOneMessage(
            role: AlteriOneRole.tool,
            content: 'the readme says hello',
            toolCallId: 'call-1',
          ),
        ]);

        final endpoint = _Endpoint();
        endpoint.replyJson(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'index': 0,
              'message': <String, Object?>{
                'role': 'assistant',
                'content': 'it says hello',
              },
              'finish_reason': 'stop',
            },
          ],
          'usage': <String, Object?>{
            'prompt_tokens': 5,
            'completion_tokens': 3,
          },
        });
        final provider = _providerFor(endpoint);

        final chunks = await provider
            .chat(AlteriOneRequest(messages: conversation), model: 'test-model')
            .toList();

        final body =
            _jsonBody(endpoint.requests.single) as Map<String, Object?>;
        final messages = body['messages']! as List<Object?>;
        expect(messages, hasLength(3));
        // The assistant turn, with `tool_calls` and the argument text as the JSON string the model
        // produced — not re-serialised, because the endpoint re-parses it and a re-serialisation
        // here would be a second place for an escaping difference to appear.
        expect((messages[1]! as Map<String, Object?>)['content'], isNull);
        expect((messages[1]! as Map<String, Object?>)['tool_calls'], <Object?>[
          <String, Object?>{
            'id': 'call-1',
            'type': 'function',
            'function': <String, Object?>{
              'name': 'fs.read',
              'arguments': '{"path":"README.md"}',
            },
          },
        ]);
        expect(
          (messages[2]! as Map<String, Object?>)['tool_call_id'],
          'call-1',
        );
        expect((messages[2]! as Map<String, Object?>)['role'], 'tool');

        // And the batch adapter, on the same provider: §3's "a non-streaming endpoint may
        // implement the interface with an adapter that emits a single final chunk". **Exactly one
        // chunk** — a delta here would report that the endpoint sent text *then*, which it did
        // not, and the whole point of the adapter is that the caller sees one result.
        expect(chunks, hasLength(1));
        final result = chunks.single as AlteriOneChatResult;
        expect(result.finishReason, AlteriOneFinishReason.stop);
        expect(result.assembledText, 'it says hello');
        expect(result.usage.totalTokens, 8);
      },
    );
  });

  group('§3.2 chunk assembly', () {
    test(
      'deltas for one call concatenate in index order, not arrival order',
      () async {
        // The rule §3.2 states, driven by a stream that violates arrival order. A fixture in order
        // proves nothing about a rule that is *about* order, and the case is not hypothetical: a
        // model is free to emit its tool calls in any order, and `parallelTools` exists precisely
        // because a model may emit more than one.
        final endpoint = _Endpoint();
        endpoint.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[
            // Call 1's *first* fragment arrives before call 0's.
            _frame(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'delta': <String, Object?>{
                    'tool_calls': <Object?>[
                      <String, Object?>{
                        'index': 1,
                        'id': 'call-b',
                        'function': <String, Object?>{
                          'name': 'web.search',
                          'arguments': '{"q":"',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            _frame(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'delta': <String, Object?>{
                    'tool_calls': <Object?>[
                      <String, Object?>{
                        'index': 0,
                        'id': 'call-a',
                        'function': <String, Object?>{
                          'name': 'fs.read',
                          'arguments': '{"path":',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            _frame(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'delta': <String, Object?>{
                    'tool_calls': <Object?>[
                      <String, Object?>{
                        'index': 1,
                        'function': <String, Object?>{'arguments': 'dart"}'},
                      },
                      <String, Object?>{
                        'index': 0,
                        'function': <String, Object?>{
                          'arguments': '"README.md"}',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            _frame(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'delta': const <String, Object?>{},
                  'finish_reason': 'tool_calls',
                },
              ],
            }),
            _frame(<String, Object?>{
              'choices': const <Object?>[],
              'usage': <String, Object?>{
                'prompt_tokens': 20,
                'completion_tokens': 8,
              },
            }),
            streamDoneSentinel,
          ],
        );

        final provider = _providerFor(endpoint);
        final result = await provider
            .chat(
              AlteriOneRequest(
                messages: AlteriOneConversation(<AlteriOneMessage>[
                  AlteriOneMessage(
                    role: AlteriOneRole.user,
                    content: 'read and search',
                  ),
                ]),
              ),
              model: 'test-model',
            )
            .last
            .then((chunk) => chunk as AlteriOneChatResult);

        expect(result.finishReason, AlteriOneFinishReason.toolCalls);
        expect(
          result.toolCallIds,
          <String>['call-a', 'call-b'],
          reason:
              '§3.2 concatenates in index order, and the ids are what a loop correlates its '
              'dispatches with',
        );
      },
    );

    test(
      'the argument JSON is parsed once, at the end, and a bad parse is -32602',
      () async {
        // The negative and its positive control, in one place. §3.2: "A call whose accumulated
        // arguments do not parse is `-32602` naming the tool, never a silent empty object." The
        // control matters: an assembler that *always* produced `-32602` would satisfy the first
        // half of this and be useless.
        final broken = _toolCallTurn(
          fragments: <String>['{"path":', 'README.md'],
          callId: 'call-1',
          toolName: 'fs.read',
        );
        await expectLater(
          broken,
          throwsA(
            isA<ProviderRefusal>()
                .having((r) => r.code, 'code', JsonRpcErrorCode.invalidParams)
                .having((r) => r.message, 'message', contains('fs.read'))
                .having((r) => r.data['tool'], 'data.tool', 'fs.read'),
          ),
          reason:
              '-32602 feeds to the model, so it has to name the tool whose arguments were '
              'wrong; the model cannot correct a parse error it cannot see',
        );

        final whole = await _toolCallTurn(
          fragments: <String>['{"path":', '"README.md"}'],
          callId: 'call-1',
          toolName: 'fs.read',
        );
        final result = whole.last as AlteriOneChatResult;
        expect(result.finishReason, AlteriOneFinishReason.toolCalls);
        expect(result.toolCallIds, <String>['call-1']);
      },
    );

    test('a turn with a finish_reason and no usage is -32603', () async {
      // §3.2's fourth rule and §4's "usage is mandatory on every successfully completed model
      // turn". A run that cannot be billed cannot be given a cost ceiling, so this is a refusal
      // and not a zero.
      final endpoint = _Endpoint();
      endpoint.reply(
        status: 200,
        contentType: eventStreamContentType,
        frames: <String>[
          _frame(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'index': 0,
                'delta': <String, Object?>{'content': 'unbillable'},
                'finish_reason': 'stop',
              },
            ],
          }),
          streamDoneSentinel,
        ],
      );
      final provider = _providerFor(endpoint);

      await expectLater(
        provider
            .chat(
              AlteriOneRequest(
                messages: AlteriOneConversation(<AlteriOneMessage>[
                  AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                ]),
              ),
              model: 'test-model',
            )
            .toList(),
        throwsA(
          isA<ProviderRefusal>()
              .having((r) => r.code, 'code', JsonRpcErrorCode.internalError)
              .having((r) => r.message, 'message', contains('usage')),
        ),
      );
    });

    test('a stream that ends with no finish_reason is -32603', () async {
      // The fifth case §3.2's last bullet implies and does not name: `finish_reason` is what
      // terminates a turn, so a stream that ends without one is a turn that did not happen. The
      // alternative — treating the end of the body as `stop` — is a run that reports a finished
      // answer the endpoint never gave.
      final endpoint = _Endpoint();
      endpoint.reply(
        status: 200,
        contentType: eventStreamContentType,
        frames: <String>[
          _frame(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'index': 0,
                'delta': <String, Object?>{'content': 'half an answer'},
              },
            ],
          }),
          streamDoneSentinel,
        ],
      );
      final provider = _providerFor(endpoint);

      await expectLater(
        provider
            .chat(
              AlteriOneRequest(
                messages: AlteriOneConversation(<AlteriOneMessage>[
                  AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                ]),
              ),
              model: 'test-model',
            )
            .toList(),
        throwsA(
          isA<ProviderRefusal>().having(
            (r) => r.code,
            'code',
            JsonRpcErrorCode.internalError,
          ),
        ),
      );
    });

    test('finish_reason: length is -32030 and not a finish', () async {
      // §3.2, verbatim: "`length` is `-32030` because the turn was truncated by a limit". A
      // truncated reply is a failure to produce an answer, and the loop must not present it as a
      // short one.
      final endpoint = _Endpoint();
      endpoint.reply(
        status: 200,
        contentType: eventStreamContentType,
        frames: <String>[
          _frame(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'index': 0,
                'delta': <String, Object?>{'content': 'truncat'},
                'finish_reason': 'length',
              },
            ],
          }),
          _frame(<String, Object?>{
            'choices': const <Object?>[],
            'usage': <String, Object?>{
              'prompt_tokens': 9,
              'completion_tokens': 4,
            },
          }),
          streamDoneSentinel,
        ],
      );
      final provider = _providerFor(endpoint);

      await expectLater(
        provider
            .chat(
              AlteriOneRequest(
                messages: AlteriOneConversation(<AlteriOneMessage>[
                  AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                ]),
              ),
              model: 'test-model',
            )
            .toList(),
        throwsA(
          isA<ProviderRefusal>()
              .having((r) => r.code, 'code', DomainErrorCode.deadlineExceeded)
              .having((r) => r.message, 'message', contains('length limit')),
        ),
      );
    });

    test('assembledCall is total: every way a call is wrong is a -32602', () {
      // Driven directly, because the four rules are about four scalar values and each is worth
      // one line rather than one stream. §3.2's second and third bullets.
      expect(
        () => assembledCall(null, null, '{}', 3),
        throwsA(
          isA<ProviderRefusal>()
              .having((r) => r.code, 'code', JsonRpcErrorCode.invalidParams)
              .having((r) => r.message, 'message', contains('index 3'))
              .having((r) => r.data['index'], 'data.index', 3),
        ),
        reason:
            'a call with neither an id nor a name has to be named by its index, because '
            '-32602 names the tool and there is no tool to name',
      );
      expect(
        () => assembledCall(null, 'fs.read', '{}', 0),
        throwsA(
          isA<ProviderRefusal>().having(
            (r) => r.message,
            'message',
            contains('fs.read'),
          ),
        ),
        reason:
            'and when the name *is* there, that is what the diagnostic names',
      );
      expect(
        () => assembledCall('call-1', null, '{}', 2),
        throwsA(
          isA<ProviderRefusal>().having(
            (r) => r.message,
            'message',
            contains('no tool name'),
          ),
        ),
      );
      expect(
        () => assembledCall('call-1', 'fs.read', '{"path":', 0),
        throwsA(
          isA<ProviderRefusal>().having(
            (r) => r.message,
            'message',
            contains('fs.read'),
          ),
        ),
      );
      expect(
        () => assembledCall('call-1', 'fs.read', '"a string"', 0),
        throwsA(
          isA<ProviderRefusal>().having(
            (r) => r.message,
            'message',
            contains('rather than a JSON object'),
          ),
        ),
        reason:
            '§3.1 maps arguments onto tools[].function.parameters, which is an object, so a '
            'scalar cannot be validated against any schema',
      );
      final call = assembledCall(
        'call-1',
        'fs.read',
        '{"path":"README.md"}',
        0,
      );
      expect(call.id, 'call-1');
      expect(call.name, 'fs.read');
      expect(call.decodedArguments, <String, Object?>{'path': 'README.md'});
    });
  });

  group('the two framing traps', () {
    test('a CRLF block terminator produces one event, not two', () async {
      // `data: x\r\n\r\n`.split('\r\n') is `['data: x', '', '']` — the blank line *and* an
      // artefact of the split. A reader that dispatches on every blank line therefore dispatches
      // twice per frame, and the symptom is not a crash: it is an extra empty event on every
      // frame, which for a tool-call delta is a spurious extra fragment.
      final endpoint = _Endpoint();
      endpoint.replyRaw(
        status: 200,
        contentType: eventStreamContentType,
        chunks: <List<int>>[
          utf8.encode(
            'data: ${_frame(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'delta': <String, Object?>{'content': 'crlf'},
                  'finish_reason': 'stop',
                },
              ],
            })}\r\n\r\n',
          ),
          utf8.encode(
            'data: ${_frame(<String, Object?>{
              'choices': const <Object?>[],
              'usage': <String, Object?>{'prompt_tokens': 2, 'completion_tokens': 1},
            })}\r\n\r\n',
          ),
          utf8.encode('data: $streamDoneSentinel\r\n\r\n'),
        ],
      );
      final provider = _providerFor(endpoint);

      final result = await provider
          .chat(
            AlteriOneRequest(
              messages: AlteriOneConversation(<AlteriOneMessage>[
                AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
              ]),
            ),
            model: 'test-model',
          )
          .last
          .then((chunk) => chunk as AlteriOneChatResult);

      expect(result.assembledText, 'crlf');
      expect(result.usage.totalTokens, 3);
    });

    test('a multi-byte character split across two chunks survives', () async {
      // The second trap. `utf8.decoder` as a stream transformer holds the partial sequence; a
      // reader that decoded each chunk on its own would raise on the first half and — in one
      // that swallowed it — silently drop a byte, corrupting every character after it.
      //
      // **An emoji rather than a Cyrillic string, and the choice belongs to the l10n gate.** A
      // Russian reply is the obvious fixture — `configuration.md` §7.4 makes `ru` a first-class
      // locale, so a user typing Russian is a real turn — but §7.4's contract test permits
      // Cyrillic in exactly one file, `lib/src/l10n/messages.dart`, and would fail *this* one for
      // containing it. A four-byte character is the stricter boundary case anyway: one byte of a
      // four-byte sequence cannot be mistaken for a complete character, so a decoder that
      // dropped a byte produces a different glyph rather than an exception — which is a failure
      // the assertion below would actually catch.
      const reply = 'ship it 🚀';
      final frame = _frame(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'index': 0,
            'delta': <String, Object?>{'content': reply},
            'finish_reason': 'stop',
          },
        ],
      });
      final usageFrame = _frame(<String, Object?>{
        'choices': const <Object?>[],
        'usage': <String, Object?>{'prompt_tokens': 2, 'completion_tokens': 1},
      });

      final bytes = utf8.encode(
        'data: $frame\r\n\r\ndata: $usageFrame\r\n\r\ndata: '
        '$streamDoneSentinel\r\n\r\n',
      );
      // Cut inside the rocket — one byte in, then two bytes on — so no boundary of the four
      // lands on a character edge.
      final rocket = _indexOfSequence(bytes, utf8.encode('🚀'));
      expect(
        rocket,
        greaterThan(0),
        reason: 'the fixture really is multi-byte',
      );
      final endpoint = _Endpoint();
      endpoint.replyRaw(
        status: 200,
        contentType: eventStreamContentType,
        chunks: <List<int>>[
          bytes.sublist(0, rocket + 1),
          bytes.sublist(rocket + 1, rocket + 3),
          bytes.sublist(rocket + 3),
        ],
      );
      final provider = _providerFor(endpoint);

      final result = await provider
          .chat(
            AlteriOneRequest(
              messages: AlteriOneConversation(<AlteriOneMessage>[
                AlteriOneMessage(role: AlteriOneRole.user, content: 'ship it?'),
              ]),
            ),
            model: 'test-model',
          )
          .last
          .then((chunk) => chunk as AlteriOneChatResult);

      expect(result.assembledText, reply);
    });

    test('SseReader joins a multi-line data field and ignores comments', () {
      // Driven directly, because these are reader rules rather than provider rules. The grammar
      // says consecutive `data:` lines concatenate with `\n`, and a reader that took the last one
      // would truncate any event an endpoint wrapped. The comment is the other half: `:` lines
      // are keep-alives, and a reader that dispatched on one would turn a heartbeat into an
      // empty event.
      final reader = SseReader();
      expect(reader.add(': keep-alive\n'), isEmpty);
      final events = reader.add('event: delta\ndata: {"a":\ndata: 1}\n\n');
      expect(events, hasLength(1));
      expect(events.single.data, '{"a":\n1}');
      expect(events.single.fields['event'], 'delta');
      expect(
        reader.add('\n'),
        isEmpty,
        reason: 'a leading blank line with nothing accumulated is not an event',
      );
    });

    test(
      'SseReader keeps the named fields and ignores the ones it does not know',
      () {
        // A Dart `switch` *statement* needs no `break` on Dart 3 — the analyzer rejects a body
        // that falls through — so the reader's field dispatch is checked by the compiler rather
        // than by a test. What is worth asserting is the behaviour the compiler cannot state: that
        // a `data:` line contributes to the payload and **not** to the named fields, that a named
        // field is replaced rather than appended, and that an unknown field is ignored instead of
        // reported, because the field set is extensible and an endpoint adding one is not a fault.
        final reader = SseReader();
        final events = reader.add(
          'event: delta\nid: 7\nretry: 100\ndata: {"a":1}\n\n',
        );
        expect(events, hasLength(1));
        expect(events.single.data, '{"a":1}');
        expect(
          events.single.fields,
          <String, String>{'event': 'delta', 'id': '7', 'retry': '100'},
          reason:
              'three named fields, and nothing contributed by the data line',
        );
        // Last one wins for a named field, against the grammar.
        final repeated = SseReader();
        expect(
          repeated
              .add('event: one\nevent: two\ndata: {}\n\n')
              .single
              .fields['event'],
          'two',
        );
        final other = SseReader();
        expect(other.add('x-custom: 1\ndata: {}\n\n').single.fields, isEmpty);
      },
    );

    test('SseReader keeps the second space of a data field', () {
      // The grammar strips exactly one optional space after the colon. `data:  a` is the payload
      // `" a"`, and a `trim()` here would corrupt a tool argument that legitimately begins with
      // a space — invisibly, because the JSON would still parse and the string would be wrong.
      final reader = SseReader();
      expect(reader.add('data:  a\n\n').single.data, ' a');
      // A colon with nothing after it is an empty value, not a missing line.
      final empty = SseReader();
      expect(empty.add('data:\n\n').single.data, isEmpty);
    });

    test(
      'an over-long SSE line is refused rather than buffered without limit',
      () {
        // The bound exists so a broken or hostile endpoint cannot grow the reader without limit,
        // and it is checked because an unbounded reader is a denial of service that looks like a
        // provider that never answers.
        final reader = SseReader(maxLineBytes: 64);
        expect(
          () => reader.add('data: ${'x' * 200}\n'),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('a malformed stream reaches the caller as -32700, not a reader exception', () async {
      // §1: "HTTP and transport errors are mapped into the taxonomy." A caller that had to catch
      // `SseFormatException`, `ProviderRefusal` and `TransportFailure` to learn that a turn
      // failed has lost the one thing the taxonomy is for — and `-32700` is exactly this case: the
      // bytes arrived and were not parseable as what the endpoint said they were.
      //
      // Driven **through the provider**, because the mapping is the provider's job and a test of
      // the reader alone would pass whichever way it went.
      final endpoint = _Endpoint();
      endpoint.replyRaw(
        status: 200,
        contentType: eventStreamContentType,
        chunks: <List<int>>[
          utf8.encode(
            'data: ${'x' * (OpenAiCompatibleProvider.maxSseLineBytes + 1)}\r\n\r\n',
          ),
        ],
      );
      final provider = _providerFor(endpoint);

      await expectLater(
        provider
            .chat(
              AlteriOneRequest(
                messages: AlteriOneConversation(<AlteriOneMessage>[
                  AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                ]),
              ),
              model: 'test-model',
            )
            .toList(),
        throwsA(
          isA<ProviderRefusal>()
              .having((r) => r.code, 'code', JsonRpcErrorCode.parseError)
              .having((r) => r.cause, 'cause', isNotNull),
        ),
      );
    });

    test('a body that is neither SSE nor JSON is -32700', () async {
      // §3 requires a stream of chunks and §3.2 requires the deltas; a body in a third format has
      // no reading that is both. The *refusal* rather than an empty turn is the point — a caller
      // handed zero chunks would report a model that said nothing, which is a different fault from
      // a model that answered in a way this build cannot read.
      final endpoint = _Endpoint();
      endpoint.reply(
        status: 200,
        contentType: 'text/html',
        jsonBody: <String, Object?>{'error': 'not a completion endpoint'},
      );
      final provider = _providerFor(endpoint);

      await expectLater(
        provider
            .chat(
              AlteriOneRequest(
                messages: AlteriOneConversation(<AlteriOneMessage>[
                  AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                ]),
              ),
              model: 'test-model',
            )
            .toList(),
        throwsA(
          isA<ProviderRefusal>().having(
            (r) => r.code,
            'code',
            JsonRpcErrorCode.parseError,
          ),
        ),
      );
    });
  });

  group('capabilities', () {
    test(
      'a missing capability in requires is refused before any request',
      () async {
        // The acceptance criterion's "explicit refusal on a missing capability", and the ordering
        // §2 requires: *"After `probe()` the core validates `requires` before the first model
        // turn… not a mysterious HTTP 400 in the middle of a run."*
        //
        // **Counted, not inferred.** A refusal that had been produced after the request would look
        // identical from the exception alone; the request count is what makes the ordering a fact.
        final endpoint = _Endpoint();
        // Step 1 (streaming) answers 200 with an event stream; step 2 (tools) answers 400.
        endpoint.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[streamDoneSentinel],
        );
        endpoint.reply(
          status: 400,
          contentType: 'application/json',
          jsonBody: <String, Object?>{
            'error': <String, Object?>{
              'message': 'tools is not supported by this model',
            },
          },
        );

        final provider = _providerFor(
          endpoint,
          ref: _ref(
            requires: const <ModelFeature>{
              ModelFeature.tools,
              ModelFeature.streaming,
            },
          ),
        );

        await expectLater(
          provider
              .chat(
                AlteriOneRequest(
                  messages: AlteriOneConversation(<AlteriOneMessage>[
                    AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                  ]),
                ),
                model: 'test-model',
              )
              .toList(),
          throwsA(
            isA<ConfigDiagnostic>()
                .having(
                  (d) => d.code,
                  'code',
                  ProviderDiagnosticCode.providerIncompatibleCapabilities,
                )
                .having((d) => d.values['name'], 'values.name', 'tools')
                .having((d) => d.errorFor('en'), 'error', contains('tools'))
                .having((d) => d.errorFor('ru'), 'error', isNotEmpty),
          ),
        );
        expect(
          endpoint.requests,
          hasLength(2),
          reason:
              'two probe requests and no model turn: §2 wants the rejection of one '
              'endpoint + model pair, not an HTTP 400 in the middle of a run',
        );
      },
    );

    test('a probe asks only for what requires names, and requires nothing costs nothing', () async {
      // §2.1 exists because a probe is a real request, so the ladder's cost is the number the
      // cache exists to reduce. The two ends of it: `requires: [tools, streaming]` is exactly
      // §2's own `openai` example and costs two requests, and an empty `requires` costs none.
      final endpoint = _Endpoint();
      endpoint.reply(
        status: 200,
        contentType: eventStreamContentType,
        frames: <String>[streamDoneSentinel],
      );
      final bare = _providerFor(endpoint, ref: _ref());
      final capabilities = await bare.ensureCompatible();
      expect(capabilities.streaming, isTrue);
      expect(
        endpoint.requests,
        isEmpty,
        reason:
            'a profile that requires nothing has nothing to validate, and paying a round trip '
            'to learn that would defeat the reason §2.1\'s cache exists',
      );

      final other = _Endpoint();
      // Two replies queued because the ladder asks twice: step 1 for `streaming`, step 2 for
      // `tools`. Queuing exactly what a test expects is the point of the double — a third
      // request would hit its "no reply queued" guard rather than pass quietly.
      for (var i = 0; i < 2; i++) {
        other.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[streamDoneSentinel],
        );
      }
      final required = _providerFor(
        other,
        ref: _ref(
          requires: const <ModelFeature>{
            ModelFeature.tools,
            ModelFeature.streaming,
          },
        ),
      );
      await required.ensureCompatible();
      expect(other.requests, hasLength(2));
      // The second request carries the probe's own tool declaration, and the name is deliberately
      // **not** a legal tool id: `toolIdGrammar` requires a dot, so a probe declaration carrying
      // one would put an id in the model's vocabulary that the registry has no owner for.
      final probeBody = _jsonBody(other.requests[1]) as Map<String, Object?>;
      final tools = probeBody['tools']! as List<Object?>;
      final declared =
          (tools.single! as Map<String, Object?>)['function']!
              as Map<String, Object?>;
      expect(declared['name'], 'alterione_capability_probe');
      expect(toolIdGrammar.hasMatch(declared['name']! as String), isFalse);
    });

    test('an endpoint that answers 2xx to stream: true but does not stream is not streaming', () async {
      // The one capability that is about the *shape* of the response rather than the acceptance
      // of a field. An endpoint that takes `stream: true` and answers with one JSON object has
      // not streamed, and a provider that believed it had would hand a caller a body with no
      // deltas to show — while every other flag said `true`.
      final endpoint = _Endpoint();
      endpoint.replyJson(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'index': 0,
            'message': <String, Object?>{
              'role': 'assistant',
              'content': 'not a stream',
            },
            'finish_reason': 'stop',
          },
        ],
        'usage': <String, Object?>{'prompt_tokens': 1, 'completion_tokens': 1},
      });
      final provider = _providerFor(
        endpoint,
        ref: _ref(requires: const <ModelFeature>{ModelFeature.streaming}),
      );
      final capabilities = await provider.probe();
      expect(capabilities.streaming, isFalse);
    });

    test('a rate limit during the probe is a probe failure, not an absent capability', () async {
      // §6: `-32002` permits a retry only after the delay the endpoint asked for. A probe that
      // swallowed a 429 would record `streaming: false` for an endpoint that streams perfectly
      // well, permanently — so the rate limit is a *failure* and the delay travels with it.
      final endpoint = _Endpoint();
      endpoint.reply(
        status: 429,
        contentType: 'application/json',
        headers: const <String, List<String>>{
          'retry-after': <String>['30'],
        },
        jsonBody: <String, Object?>{
          'error': <String, Object?>{'message': 'slow down'},
        },
      );
      final provider = _providerFor(
        endpoint,
        ref: _ref(requires: const <ModelFeature>{ModelFeature.streaming}),
      );

      await expectLater(
        provider.probe(),
        throwsA(
          isA<ProviderProbeException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 30),
          ),
        ),
      );
      // And it is not memoised: a failure is nobody answering, so the next caller may try again.
      expect(provider.lastProbe, isNull);
    });

    test('an unreachable endpoint fails the probe rather than reporting seven falses', () async {
      // The distinction `probe.dart` is built around. A transport failure is not a statement by
      // anybody, and recording `false` for it would present a provider as permanently
      // incompatible — after which §5's failover would never route to it again.
      final endpoint = _Endpoint();
      endpoint.failWith(
        TransportFailure('connection refused', retryable: true),
      );
      final provider = _providerFor(
        endpoint,
        ref: _ref(requires: const <ModelFeature>{ModelFeature.tools}),
      );

      await expectLater(
        provider.probe(),
        throwsA(
          isA<ProviderProbeException>().having(
            (e) => e.cause,
            'cause',
            isNotNull,
          ),
        ),
      );
      expect(provider.capabilities, isNull);
    });

    test(
      'a context window is validated as positive and never measured',
      () async {
        // §2 says exactly that much: *"`contextWindow` is validated as a positive number."*
        // Measuring it would mean a request with an N-token prompt for every N, and the answer
        // would be the endpoint's billing behaviour rather than its capability.
        final endpoint = _Endpoint();
        endpoint.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[streamDoneSentinel],
        );
        final provider = _providerFor(
          endpoint,
          ref: _ref(requires: const <ModelFeature>{ModelFeature.streaming}),
        );
        final capabilities = await provider.probe();
        expect(capabilities.contextWindow, greaterThan(0));
        expect(
          () => AlteriOneModelCapabilities(
            tools: true,
            parallelTools: true,
            streaming: true,
            jsonMode: true,
            promptCaching: true,
            seed: true,
            contextWindow: 0,
          ),
          throwsA(isA<AssertionError>()),
          reason:
              'a context window of zero is a broken probe, and the constructor is the only '
              'point at which a caller can be stopped',
        );
      },
    );

    test(
      'cached tokens flip promptCaching, because a request cannot',
      () async {
        // §2's probe cannot establish `promptCaching` — nothing in a request makes an endpoint
        // report cached tokens — so the only evidence in the product is a real turn whose usage
        // carries a non-zero `prompt_tokens_details.cached_tokens`. §4 is explicit about why that
        // matters: it is the difference between two runs of the same script costing almost nothing
        // and costing a great deal.
        final endpoint = _Endpoint();
        // Step 1 of the probe, then the turn itself — two replies, queued in the order the
        // requests arrive.
        endpoint.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[streamDoneSentinel],
        );
        endpoint.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[
            _frame(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'delta': <String, Object?>{'content': 'warm'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            _frame(<String, Object?>{
              'choices': const <Object?>[],
              'usage': <String, Object?>{
                'prompt_tokens': 100,
                'completion_tokens': 2,
                'prompt_tokens_details': <String, Object?>{'cached_tokens': 90},
              },
            }),
            streamDoneSentinel,
          ],
        );
        final provider = _providerFor(
          endpoint,
          ref: _ref(requires: const <ModelFeature>{ModelFeature.streaming}),
        );
        expect((await provider.probe()).promptCaching, isFalse);

        await provider
            .chat(
              AlteriOneRequest(
                messages: AlteriOneConversation(<AlteriOneMessage>[
                  AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                ]),
              ),
              model: 'test-model',
            )
            .toList();
        expect(
          provider.capabilities!.promptCaching,
          isTrue,
          reason:
              'the observation is folded into the matrix rather than frozen at the probe, '
              'because a probe could never have established it',
        );
        // A second probe reports the observation rather than asking again — and a fresh provider
        // over the same endpoint still has to ask, because the observation lives with the provider
        // that made the turn.
        final second = _Endpoint();
        second.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[streamDoneSentinel],
        );
        final warm = _providerFor(
          second,
          ref: _ref(requires: const <ModelFeature>{ModelFeature.streaming}),
        );
        expect((await warm.probe()).promptCaching, isFalse);
      },
    );
  });

  group('refusals before the wire', () {
    test('a profile that names apiKeyEnv and has no credential is config.missing_env', () {
      // A request with no `Authorization` header is answered with a 401 whose message is about
      // authentication, which is a diagnosis about the wrong thing. `apiKeyEnv` names a
      // *variable* (`configuration.md` §4.1) and the composition root resolves it; a name with
      // no value is a configuration fault, and it is raised before anything is spent.
      //
      // Built through the **provider's constructor** rather than through a helper, because the
      // constructor is where the rule lives and a helper that reproduced it would be a second
      // implementation of the thing being tested.
      expect(
        () => OpenAiCompatibleProvider(
          ref: _ref(apiKeyEnv: 'OPENAI_API_KEY'),
          exchange: ChatExchange(client: _Endpoint(), apiKey: null),
          clock: FakeClock(),
        ),
        throwsA(
          isA<ConfigDiagnostic>()
              .having((d) => d.values['name'], 'values.name', 'OPENAI_API_KEY')
              .having(
                (d) => d.errorFor('en'),
                'error',
                contains('OPENAI_API_KEY'),
              )
              .having((d) => d.errorFor('ru'), 'error', isNotEmpty),
        ),
      );
    });

    test('a base URL the egress policy cannot rule on is refused in the constructor', () {
      // `install-and-update.md` §1 evaluates the egress rules against the request URI, so a
      // scheme with no verdict is a request the policy has no answer for. Checked at
      // construction so the fault is a configuration diagnostic and not a transport failure
      // somebody has to reverse-engineer.
      expect(
        () => OpenAiCompatibleProvider(
          ref: _ref(baseUrl: 'file:///etc/passwd'),
          exchange: ChatExchange(client: _Endpoint(), apiKey: 'k'),
          clock: FakeClock(),
        ),
        throwsA(
          isA<ConfigDiagnostic>()
              .having((d) => d.values['field'], 'values.field', 'baseURL')
              .having((d) => d.path, 'path', 'model.providers'),
        ),
      );
    });

    test(
      'a model other than the probed one is a configuration fault',
      () async {
        // §2's matrix belongs to an `endpoint + model` *pair*. A probe of `ref.modelId` cannot
        // speak for a different model, so asking for one is a fault rather than a preference —
        // and it is checked before the request, for the same reason the missing credential is.
        final endpoint = _Endpoint();
        endpoint.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[streamDoneSentinel],
        );
        final provider = _providerFor(
          endpoint,
          ref: _ref(requires: const <ModelFeature>{ModelFeature.streaming}),
        );
        await expectLater(
          provider
              .chat(
                AlteriOneRequest(
                  messages: AlteriOneConversation(<AlteriOneMessage>[
                    AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                  ]),
                ),
                model: 'some-other-model',
              )
              .toList(),
          throwsA(isA<ConfigDiagnostic>()),
        );
        expect(
          endpoint.requests,
          isEmpty,
          reason:
              'nothing at all went out, not even the probe: the model is checked before '
              'ensureCompatible runs, because a probe of ref.modelId cannot speak for a different '
              'model and spending a handshake to learn that would be a request for a fault',
        );
      },
    );

    test(
      'a request asking for a capability the pair lacks is refused, not sent',
      () async {
        // `AlteriOneRequest.jsonMode` and `.seed` are *request* fields, and §2's rule is that
        // `requires` is checked before the first turn — but a request that asks for something
        // `requires` never named is the same failure arriving by another door. Without this check
        // it is a 400 in the middle of a run, which is the thing §2 says to prevent.
        final endpoint = _Endpoint();
        endpoint.reply(
          status: 200,
          contentType: eventStreamContentType,
          frames: <String>[streamDoneSentinel],
        );
        final provider = _providerFor(
          endpoint,
          ref: _ref(requires: const <ModelFeature>{ModelFeature.streaming}),
        );

        await expectLater(
          provider
              .chat(
                AlteriOneRequest(
                  messages: AlteriOneConversation(<AlteriOneMessage>[
                    AlteriOneMessage(role: AlteriOneRole.user, content: 'hi'),
                  ]),
                  jsonMode: true,
                ),
                model: 'test-model',
              )
              .toList(),
          throwsA(
            isA<ConfigDiagnostic>().having(
              (d) => d.code,
              'code',
              ProviderDiagnosticCode.providerIncompatibleCapabilities,
            ),
          ),
        );
        expect(
          endpoint.requests.where(
            (r) => r.uri.path.endsWith('/chat/completions'),
          ),
          hasLength(1),
          reason: 'the probe went out; the refused turn did not',
        );
      },
    );
  });

  group('the specification, parsed', () {
    test('the finish reasons and the diagnostics are the ones the documents declare', () {
      // The table in `docs/architecture/providers.md` §3.2 and the taxonomy in
      // `docs/reference/error-codes.md` §3/§4 are parsed, so a change to a document and a change to
      // the code cannot agree by accident — the arrangement the registry's contract test uses for
      // `overview.md` §5. `dart:io` is here for the file reads and for nothing else; the package
      // itself imports no `dart:io`.
      //
      // The path is found by **walking up from the working directory**, the arrangement
      // `registry_dispatch_contract_test.dart`'s `_repositoryRoot` already establishes. The
      // acceptance command is `melos exec --scope=alteri_one_core -- dart test …` and melos runs
      // it *in the package*, so a test that opened `docs/…` relative to the working directory
      // would pass when run from the root by hand and fail in the one place it has to work.
      final spec = File(
        '${_repositoryRoot().path}/docs/architecture/providers.md',
      ).readAsStringSync();
      for (final reason in <String>['tool_calls', 'stop', 'length']) {
        expect(
          spec,
          contains('`$reason`'),
          reason: '§3.2 names $reason as a finish_reason this build must map',
        );
      }
      expect(
        spec,
        contains('-32030'),
        reason:
            '§3.2 makes a truncated turn -32030, and error-codes.md §1 gives that number a '
            'name',
      );
      expect(
        spec,
        contains('Future<AlteriOneModelCapabilities> probe()'),
        reason:
            '§1 declares probe on the port and this task implements it; a provider without '
            'one would be a turn whose cost nothing knows',
      );

      // And the taxonomy, from the document that declares it. `provider.probe_stale` is the
      // diagnostic §2.1's TTL raises, and it was already in `allDiagnosticCodes` before this
      // task — so the check here is that a *documented* code has somewhere to be raised from and
      // nowhere in this package invents a tenth provider code to go with it.
      final codes = File(
        '${_repositoryRoot().path}/docs/reference/error-codes.md',
      ).readAsStringSync();
      for (final code in <String>[
        'provider.unavailable',
        'provider.rate_limited',
        'provider.incompatible_capabilities',
        'provider.probe_stale',
      ]) {
        expect(
          codes,
          contains('`$code`'),
          reason:
              '§3 declares $code, and every DiagnosticCode needs a catalogue entry',
        );
      }
      expect(
        codes,
        contains('| `8` | `provider` |'),
        reason:
            'a missing capability exits 8, and §4.1 maps provider.incompatible_capabilities '
            'to it — the refusal this task raises has to land on the exit code an operator sees',
      );
    });

    test('a ProfileException is not what a missing capability raises', () {
      // A distinction worth one line: `ConfigDiagnostic` is returned and collected by the
      // pipeline, and `ProfileException` is the single-diagnostic throw a composition root
      // chooses. A provider refusal has to be catchable as the former, because `doctor` collects
      // many and the CLI prints them.
      expect(
        () => ProfileException(
          ConfigDiagnostic(
            code: ProviderDiagnosticCode.providerIncompatibleCapabilities,
            values: const <String, Object?>{'name': 'tools'},
          ),
        ),
        returnsNormally,
      );
    });
  });
}

/// The offset of the first occurrence of [needle] in [haystack], or −1.
///
/// `List<int>.indexOf` takes a single element, not a sequence, and a byte-sequence search written
/// out here is four lines against a one-line mistake. It is a test helper rather than a library
/// one because nothing in the product needs to find a byte pattern in a body.
int _indexOfSequence(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return -1;
  outer:
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) continue outer;
    }
    return start;
  }
  return -1;
}

/// The repository root, found by walking up from the working directory.
///
/// The same arrangement `registry_dispatch_contract_test.dart` uses, and for the same reason: the
/// acceptance command is `melos exec --scope=alteri_one_core -- dart test …` and melos runs it *in
/// the package*, so a relative path would work from the root by hand and fail in the one place it
/// has to work. The portability defect `bugfix/governance-test-portability` fixed was exactly
/// this shape of assumption.
Directory _repositoryRoot() {
  const relative = 'docs/architecture/providers.md';
  var directory = Directory.current;
  while (true) {
    if (File('${directory.path}/$relative').existsSync() &&
        Directory('${directory.path}/packages').existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        '$relative and packages/ not found above ${Directory.current.path}; this test needs the '
        'repository, and it looks for the file rather than assuming where it was run from',
      );
    }
    directory = parent;
  }
}

/// A provider over [endpoint], with a chain entry the test chose.
///
/// [ref] is what a test varies: the default entry requires nothing, so a test that wants a *turn*
/// pays no probe request — which is the product's own rule (`providers.md` §2) and not a
/// convenience invented for the test. A test about the probe itself passes a `ref` whose
/// `requires` is populated and lets the ladder run.
OpenAiCompatibleProvider _providerFor(_Endpoint endpoint, {ProviderRef? ref}) =>
    OpenAiCompatibleProvider(
      ref: ref ?? _ref(),
      exchange: ChatExchange(client: endpoint, apiKey: 'test-key'),
      clock: FakeClock(),
    );

/// A chain entry, for the tests that vary the fields the probe and the request read.
ProviderRef _ref({
  String id = 'local',
  String baseUrl = 'http://127.0.0.1:11434/v1',
  String modelId = 'test-model',
  String? apiKeyEnv,
  Set<ModelFeature> requires = const <ModelFeature>{},
}) => ProviderRef(
  id: id,
  baseUrl: baseUrl,
  modelId: modelId,
  apiKeyEnv: apiKeyEnv,
  requires: requires,
);

/// One `data:` frame's JSON, built the way an endpoint would send it.
String _frame(Map<String, Object?> body) => jsonEncode(body);

/// The decoded body of a request the double received.
Object? _jsonBody(HttpRequestSpec spec) =>
    jsonDecode(utf8.decode(spec.body!, allowMalformed: false));

/// A turn that ends on one tool call, split across [fragments] of argument JSON.
Future<List<AlteriOneChatChunk>> _toolCallTurn({
  required List<String> fragments,
  required String callId,
  required String toolName,
}) {
  final endpoint = _Endpoint();
  endpoint.reply(
    status: 200,
    contentType: eventStreamContentType,
    frames: <String>[
      for (var i = 0; i < fragments.length; i++)
        _frame(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'index': 0,
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    if (i == 0) 'id': callId,
                    'function': <String, Object?>{
                      if (i == 0) 'name': toolName,
                      'arguments': fragments[i],
                    },
                  },
                ],
              },
            },
          ],
        }),
      _frame(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'index': 0,
            'delta': const <String, Object?>{},
            'finish_reason': 'tool_calls',
          },
        ],
      }),
      _frame(<String, Object?>{
        'choices': const <Object?>[],
        'usage': <String, Object?>{'prompt_tokens': 12, 'completion_tokens': 6},
      }),
      streamDoneSentinel,
    ],
  );
  final provider = _providerFor(endpoint);
  return provider
      .chat(
        AlteriOneRequest(
          messages: AlteriOneConversation(<AlteriOneMessage>[
            AlteriOneMessage(
              role: AlteriOneRole.user,
              content: 'read the readme',
            ),
          ]),
        ),
        model: 'test-model',
      )
      .toList();
}

/// An [HttpClientPort] double that answers from a queue of scripted responses.
///
/// **Deliberately at the port rather than at `package:http`.** Two reasons, and the first is
/// the one that makes this file's assertions possible: `HttpRequestSpec` and `HttpResponse` are
/// *bytes and headers*, so a test can choose where the body is split — which is the only way to
/// reach §3.2's "arbitrary byte boundaries" and the two framing traps. The second is that a
/// `dart:io` client would be a real socket, and the blocking chain must not reach the network.
class _Endpoint implements HttpClientPort {
  final List<_Reply> _queue = <_Reply>[];
  final List<HttpRequestSpec> requests = <HttpRequestSpec>[];
  TransportFailure? _failure;

  /// Queues a reply for the next request.
  void enqueue(_Reply reply) => _queue.add(reply);

  /// Queues a reply: an event stream from [frames], or one JSON object from [jsonBody].
  void reply({
    required int status,
    required String contentType,
    List<String>? frames,
    Map<String, Object?>? jsonBody,
    Map<String, List<String>> headers = const <String, List<String>>{},
  }) => enqueue(
    _Reply(
      status: status,
      contentType: contentType,
      frames: frames,
      jsonBody: jsonBody,
      headers: headers,
    ),
  );

  /// Queues an event-stream reply whose body arrives as exactly [chunks].
  void replyRaw({
    required int status,
    required String contentType,
    required List<List<int>> chunks,
  }) =>
      enqueue(_Reply(status: status, contentType: contentType, chunks: chunks));

  /// Queues a single-JSON-completion reply.
  void replyJson(Map<String, Object?> body) => enqueue(
    _Reply(status: 200, contentType: 'application/json', jsonBody: body),
  );

  /// Makes the next request fail the way a refused connection does.
  void failWith(TransportFailure failure) => _failure = failure;

  @override
  Future<HttpResponse> send(HttpRequestSpec request) async {
    requests.add(request);
    final failure = _failure;
    if (failure != null) throw failure;
    if (_queue.isEmpty) {
      throw StateError(
        'the endpoint double received ${requests.length} requests and has '
        '${_queue.length} replies queued. A test that does not say what the endpoint answers is '
        'a test that would have passed on a provider that sent nothing',
      );
    }
    return _queue.removeAt(0).respond();
  }

  @override
  Future<void> close() async {}

  @override
  String toString() => '_Endpoint(${requests.length} requests)';
}

/// One scripted reply.
class _Reply {
  _Reply({
    required this.status,
    required this.contentType,
    this.frames,
    this.chunks,
    this.jsonBody,
    this.headers = const <String, List<String>>{},
  });

  /// The status to answer with.
  final int status;

  /// The `content-type` to answer with.
  final String contentType;

  /// The SSE `data:` payloads, in order, including the sentinel.
  final List<String>? frames;

  /// The raw body bytes, when a test is choosing the boundaries itself.
  final List<List<int>>? chunks;

  /// The body, when the reply is one JSON object.
  final Map<String, Object?>? jsonBody;

  /// Extra headers.
  final Map<String, List<String>> headers;

  /// The [HttpResponse] this reply stands for.
  HttpResponse respond() {
    final List<List<int>> body;
    if (chunks != null) {
      body = chunks!;
    } else if (jsonBody != null) {
      body = <List<int>>[utf8.encode(jsonEncode(jsonBody))];
    } else {
      final frames = this.frames ?? const <String>[];
      // `body: <List<int>>` instead of a `Stream`, so a stream-scoped test would need an
      // `async*` here; one list is enough and keeps the double's control flow visible.
      final buffer = StringBuffer();
      for (final frame in frames) {
        buffer
          ..write('data: $frame\r\n')
          ..write('\r\n');
      }
      body = <List<int>>[utf8.encode(buffer.toString())];
    }
    return HttpResponse(
      statusCode: status,
      headers: <String, List<String>>{
        'content-type': <String>[contentType],
        ...headers,
      },
      body: Stream<List<int>>.fromIterable(body),
    );
  }
}
