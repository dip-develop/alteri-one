// The contract of the registry, the event bus and the prefix dispatcher. Task 0.12.
//
// What this file is: the mechanical half of "the registry binds a tool to a plugin, the bus
// publishes typed events, and the dispatcher routes `core/*`, `$/` and `<namespace>.*` by
// prefix without core changes when a capability is added" — `docs/process/task-breakdown.md`
// §`0.12`. The rules it asserts are written down in `docs/architecture/overview.md` §4 (the
// composition root) and §5 (the dispatch table, the single owner per namespace and the
// bind-time failure with no implicit priority), §6 (one bus carrying `traceId`),
// `docs/concepts.md` §2 (the identifier grammar, and the sentence "the tool namespace prefix
// is the **dispatch key**") and §2.1 (the reserved prefixes), `docs/architecture/engine.md` §4
// (the canonical event set and the mandatory envelope), `docs/architecture/protocol.md` §1.2
// ("an unknown method is `-32601`, not a best-effort cast"),
// `docs/extensibility/plugins.md` §1 and §2, and `docs/reference/error-codes.md` §1 and §3.
//
// The greppable acceptance string for the task is the description of the first test below:
// "registry routes namespaced methods without core edits".
//
// ## What this file asserts that a "no errors" check would not
//
// A dispatcher that returned the right result for `web.search` and threw for everything else
// would satisfy `expect(outcome.isDelivered, isTrue)` once. So almost nothing here is a
// presence check:
//
// - the *negative* cases are the ones with codes attached — `-32601` for a namespace nobody
//   owns, `-32603` for a handler that throws, `extension.duplicate_id` for a second owner,
//   `config.manifest_drift` for a tool id in a namespace the unit does not own;
// - the same call is driven twice, once to a handler that answers and once to a handler that
//   throws, so the redaction assertion has a positive control: the value the `-32603` must not
//   carry is the one the successful call *does* carry;
// - "no core edit" is made mechanical rather than asserted as a claim, by counting the
//   namespaces the product's own source spells. See that test for what it can and cannot say.
//
// ## `dart:io` is here, and it is legitimate
//
// Two of the checks read a specification file: the dispatch table of `overview.md` §5 and the
// reserved prefixes of `concepts.md` §2.1 are *parsed*, so that a change to the documents and a
// change to the code cannot agree by accident. The package itself imports no `dart:io` —
// `overview.md` §3 — and a test is the right place for it, for the reason
// `configuration.md` §7.4 asks for explicitly.

import 'dart:convert';
import 'dart:io';

import 'package:alteri_one_core/core.dart';

// The diagnostic-code enums, for the same reason `core.dart` is imported: the registry's and the
// bus's failures carry a `DiagnosticCode`, and `core.dart` does not re-export the enum that
// `error-codes.md` §3's table is compiled into. Naming the *entries* here rather than only
// their spellings ties both producers to the declared taxonomy — and `profile_contract_test.dart`
// already cross-checks that taxonomy against §3, so the chain from a dispatch failure to a row
// in the table is closed rather than parallel.
import 'package:alteri_one_core/profile.dart';

// Through the public surface, on purpose: a rename or a move in `lib/` should break this test
// rather than quietly make it assert a property of internals. The protocol package is
// imported rather than reached through `core.dart` because the two control-plane method names,
// the envelope types and the error taxonomy are the *other* half of every rule below — §5's
// second row is `$/cancelRequest` and `$/progress`, and those are constants in
// `alteri_one_protocol`, not strings this file may invent.
import 'package:alteri_one_protocol/alteri_one_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('the dispatch table', () {
    test('registry routes namespaced methods without core edits', () async {
      // The headline, and the task's greppable acceptance string. Three claims, and the third
      // is the one the task is named for:
      //
      // - **two registered plugins**: `web` and `fs`, the two `tools/` packages
      //   `overview.md` §2.2's table names, each under its own namespace;
      // - **prefix dispatch**: each of §5's three rows reaches the owner the table names, and
      //   the handler sees the method under the spelling the row uses;
      // - **no core edits**: the routing is a function of the registry, not of a table in the
      //   core. The evidence is in the test that follows, and it is *not* a diff — see there.
      final web = _FakeHandler();
      final fs = _FakeHandler();
      final engine = _FakeHandler();
      final control = _FakeHandler();
      final registry = _bound(
        <ExtensionUnit>[
          ExtensionUnit(
            namespace: MethodNamespace('web'),
            handler: web,
            toolIds: toolPackages['web']!,
          ),
          ExtensionUnit(
            namespace: MethodNamespace('fs'),
            handler: fs,
            toolIds: toolPackages['fs']!,
          ),
        ],
        seeded: <ExtensionUnit>[_engineUnit(engine), _controlUnit(control)],
      );
      final dispatcher = MethodDispatcher(registry);
      expect(toolPackages.keys.toList(), <String>['web', 'fs']);

      // The row for a `tools/` package, spelled as a tool id.
      final search = await dispatcher.route(MethodCall('web.search'));
      expect(search.isDelivered, isTrue);
      expect(search.result!.value['namespace'], 'web');
      expect(search.result!.value['method'], 'web.search');
      expect(web.seen, <String>[
        'web.search',
      ], reason: 'only its own owner was called');

      // The same row for the other plugin, and the proof that the two did not cross.
      final read = await dispatcher.route(MethodCall('fs.read'));
      expect(read.isDelivered, isTrue);
      expect(fs.seen, <String>['fs.read']);
      expect(web.seen, <String>['web.search']);

      // Row one: `core/*`, the engine's own built-in methods, spelled with a slash.
      expect(
        (await dispatcher.route(MethodCall('core/run'))).isDelivered,
        isTrue,
      );
      expect(engine.seen, <String>['core/run']);

      // Row one again, spelled with a dot — `core.initialize` is the spelling the *shipped*
      // handshake uses, so it is a method the engine has to be able to receive.
      final initialize = await dispatcher.route(MethodCall(initializeMethod));
      expect(initialize.isDelivered, isTrue);
      expect(engine.operations, <String>['run', 'initialize']);

      // Row two, `$/`, is a notification and is exercised in the notification test below. It
      // is *seeded* here, and the seed is the point: §5's owner for `$` is
      // `alteri_one_protocol`, which is built into the registry rather than registered by a
      // composition root, and a caller that forgets to seed it gets a registry in which the
      // control plane is simply absent.
      expect(registry.owns(MethodNamespace.control), isTrue);
      expect(control.seen, isEmpty, reason: 'no call reached it yet');

      // The two ownership rules kept every id to exactly one owner, and the registry is the
      // only place that could have said otherwise.
      expect(registry.namespaces.map((n) => n.value).toList(), <String>[
        r'$',
        'core',
        'fs',
        'web',
      ]);
      expect(registry.toolIds, <String>[
        'core.initialize',
        'core.run',
        'fs.delete',
        'fs.edit',
        'fs.list',
        'fs.read',
        'fs.write',
        'web.fetch',
        'web.search',
      ]);
      for (final toolId in registry.toolIds) {
        expect(registry.implementsTool(toolId), isTrue, reason: toolId);
        expect(
          registry.namespaceForTool(toolId),
          MethodNamespace.dispatchKeyOf(toolId),
          reason: 'concepts.md §2: the dotted prefix is the dispatch key',
        );
        expect(registry.handlerForTool(toolId), isNotNull, reason: toolId);
      }
      expect(registry[MethodNamespace('web')]!.handler, same(web));
      expect(registry[MethodNamespace('fs')]!.handler, same(fs));
    });

    test(
      'a namespace this build has never heard of routes by the same path',
      () async {
        // The "without core edits" half, stated as far as a test can state it.
        //
        // **A test cannot assert the absence of an edit to `lib/`.** What it can do is assert the
        // two facts that make the claim true, and both are here:
        //
        // 1. **The routing is a function of the registry.** A *second* registry, built here in
        //    the test, owns `memory` — a `plugins/` package (`overview.md` §2.2's third row of
        //    the v1 set) that the first registry does not own — and `memory.search` routes to it
        //    through the same `MethodDispatcher` and the same `MethodCall` with no argument
        //    naming a namespace. The first registry refuses the same call with `-32601`, so the
        //    two registries genuinely differ and the difference is the data, not the code.
        // 2. **The core names exactly two namespaces.** `_declaredNamespaces` parses
        //    `lib/src/core/namespace.dart` and finds the two `static const MethodNamespace`
        //    declarations. Both are in [reserved]. There is no third constant, so there is
        //    nothing for a fourth namespace to be added to: a new one can only arrive as a value
        //    handed to `ExtensionRegistry.build`, which is the whole mechanism §5 promises.
        //
        // Together those are the claim as a test can hold it. What they do **not** cover is a
        // future edit that adds a `case` to a `switch` in the dispatcher — see
        // `no product library imports an extension package` in
        // `test/workspace/workspace_contract_test.dart` for the gate that keeps the source-level
        // half of the same claim honest, and the note in `dispatcher.dart` about why there is no
        // prefix branch.
        final first = _bound(
          <ExtensionUnit>[
            _unit('web', <String>['web.search']),
          ],
          seeded: <ExtensionUnit>[
            _engineUnit(_FakeHandler()),
            _controlUnit(_FakeHandler()),
          ],
        );
        final memory = _FakeHandler();
        final second = _bound(
          <ExtensionUnit>[
            _unit('web', <String>['web.search']),
            _unit('memory', <String>[
              'memory.search',
              'memory.remember',
            ], handler: memory),
          ],
          seeded: <ExtensionUnit>[
            _engineUnit(_FakeHandler()),
            _controlUnit(_FakeHandler()),
          ],
        );

        expect(first.owns(MethodNamespace('memory')), isFalse);
        expect(second.owns(MethodNamespace('memory')), isTrue);

        final before = await MethodDispatcher(first)
            .route(MethodCall('memory.search'));
        expect(before.isDelivered, isFalse);
        expect(before.error!.wireCode, -32601);

        final after = await MethodDispatcher(second)
            .route(MethodCall('memory.search'));
        expect(after.isDelivered, isTrue);
        expect(after.result!.value['namespace'], 'memory');
        expect(memory.seen, <String>['memory.search']);

        // The declared namespaces in the product's own source, and the second half of the claim.
        final declared = _declaredNamespaces(_repositoryRoot());
        expect(
          declared.map((entry) => entry.$2).toSet(),
          reserved.map((namespace) => namespace.value).toSet(),
          reason:
              'the core spells only the reserved namespaces, so there is no table a new one could '
              'be added to. A third `static const MethodNamespace` here is a core edit and the '
              'defeats §5',
        );
        expect(
          declared,
          hasLength(reserved.length),
          reason: 'a declared constant that is not reserved has no owner in §5',
        );
      },
    );

    test('the separator is a fact about the document, not about the code', () {
      // The documents use two separators and do not reconcile them, and `namespace.dart`'s
      // library documentation says so and explains why the code accepts all of them: the
      // namespace is the **leading `[a-z][a-z0-9_]*` run** and the separator is whatever
      // follows it. These are the three spellings, and each must resolve to the namespace the
      // document means, with the operation being the part after the separator.
      //
      // `core.initialize` is the third spelling and the one that cannot be waved away: it is
      // the method `alteri_one_protocol`'s shipped handshake sends, so a dispatcher that
      // refused a dotted method would refuse the handshake.
      //
      // `$/cancelRequest` is a fourth row and it is *not* here: `$` is not something the
      // grammar can produce, so `MethodCall` refuses it before a namespace is ever compared.
      // That is the control plane's own test, below, and it fails there.
      final cases = <(String, String, String)>[
        // (method, namespace, operation)
        ('core/run', 'core', 'run'),
        ('web.search', 'web', 'search'),
        ('core.initialize', 'core', 'initialize'),
      ];
      for (final (method, namespace, operation) in cases) {
        final parsed = MethodNamespace(namespace);
        final call = MethodCall(method);
        expect(call.namespace.value, namespace, reason: method);
        expect(call.operation, operation, reason: method);
        expect(
          call.method,
          method,
          reason: 'the call does not rewrite the method',
        );
        expect(
          MethodNamespace.of(method),
          parsed,
          reason: 'of() and the call must agree, or a caller reading either one is misled',
        );
        // `method()` rebuilds the **slashed** spelling, and the difference is the whole
        // tolerance rather than an accident: for `core/run` it is the identity, and for
        // `core.initialize` and `web.search` it is `core/initialize` and `web/search` — the same
        // destination written the other way, which is what makes the two spellings one address.
        // `$/cancelRequest` is the one that cannot round-trip at all, and the reason is its own
        // test: `$` is not something the grammar can parse back out of a method.
        expect(
          parsed.method(operation),
          '$namespace/$operation',
          reason: method,
        );
        expect(
          MethodNamespace.of(method),
          MethodNamespace.of(parsed.method(operation)),
          reason:
              'the two spellings of one address must resolve to one namespace, or a reader '
              'holding `web/search` and a peer sending `web.search` are looking at two places',
        );
      }
      expect(MethodNamespace('core').method('initialize'), 'core/initialize');
      expect(MethodNamespace.core.method('run'), 'core/run');

      // The namespace grammar is a **prefix** pattern, and `namespace.dart` says it must not
      // be used with `hasMatch` against a whole id. The two members that read a whole id both
      // say which pattern they use, and the difference is visible here.
      expect(
        namespaceGrammar.matchAsPrefix('web.search')!.group(0),
        'web',
        reason:
            'the leading run is the namespace and the separator is the rest',
      );
      expect(
        toolIdGrammar.hasMatch('web.search'),
        isTrue,
        reason: 'the whole-id pattern is the one for a tool id',
      );
      expect(
        toolIdGrammar.hasMatch('websearch'),
        isFalse,
        reason: 'one segment is not a tool id: concepts.md §2 requires the dot',
      );
      expect(eventTopicGrammar.hasMatch('core/step_completed'), isTrue);
      expect(
        eventTopicGrammar.hasMatch('a/b/c'),
        isTrue,
        reason: '§2 writes `+`',
      );
      expect(
        eventTopicGrammar.hasMatch('core'),
        isFalse,
        reason: '§2 requires a slash',
      );
    });

    test('a method with no operation is an ArgumentError, not a routed call', () async {
      // `MethodCall`'s constructor refuses it, and the reason is in its documentation: a peer
      // addresses a method *inside* a namespace, and accepting a bare prefix would let it
      // address the namespace itself — which the core would then answer out of its own
      // handler, as though a peer had asked for a built-in.
      //
      // `MethodNamespace.of` is a prefix match and *does* answer `core`; the refusal is
      // deliberately somewhere else, because "what a nameless method means" is not a question
      // about namespaces.
      expect(MethodNamespace.of('core'), MethodNamespace.core);
      expect(MethodNamespace.of('web'), MethodNamespace('web'));
      expect(
        MethodNamespace.of('Web/run'),
        isNull,
        reason: 'uppercase is not the grammar',
      );
      expect(
        MethodNamespace.of('9web/run'),
        isNull,
        reason: 'a digit cannot lead',
      );
      expect(MethodNamespace.of(''), isNull);

      expect(() => MethodCall('core'), throwsArgumentError);
      expect(() => MethodCall('web'), throwsArgumentError);
      // `MethodCall(r'$')` is also an `ArgumentError`, but for the *other* reason: `$` is not
      // something the namespace grammar can produce, so the call has no namespace before the
      // question of its operation arises. Asserted here so the two refusals are not confused —
      // the control plane's version of this is a test of its own, and it fails.
      expect(() => MethodCall(r'$'), throwsArgumentError);
      // And a method that does not begin with a namespace at all is refused for that same
      // other reason, naming the grammar.
      expect(() => MethodCall('/run'), throwsArgumentError);
      expect(() => MethodCall('Core/run'), throwsArgumentError);

      // A refused method never reaches a handler, so the registry's own owner is untouched.
      final handler = _FakeHandler();
      final registry = _bound(
        <ExtensionUnit>[
          _unit('web', <String>['web.search'], handler: handler),
        ],
        seeded: <ExtensionUnit>[
          _engineUnit(_FakeHandler()),
          _controlUnit(_FakeHandler()),
        ],
      );
      final dispatcher = MethodDispatcher(registry);
      expect(dispatcher.canRoute(MethodCall('web.search')), isTrue);
      expect(dispatcher.canRoute(MethodCall('nope/go')), isFalse);
      // `canRoute` is a question about the registry and not a dispatch, so asking it must not
      // have called the handler — that is `tools.md` §1.2's step 2, filtering by namespace
      // scope before a call is built.
      expect(handler.seen, isEmpty);
      expect(registry.handlerForTool('web.search'), same(handler));
    });

    test('an unknown namespace is -32601 and names the namespaces that were available', () async {
      // `protocol.md` §1.2: "An unknown method is `-32601`, not a best-effort cast", and
      // `error-codes.md` §1 gives "Method or tool not found" for `-32601`. The `data` carries
      // the known namespaces so a reader can see what *was* available: a bare "not found" on a
      // typo'd namespace sends the reader to the dispatcher instead of to their own `register`.
      final handler = _FakeHandler();
      final registry = _bound(
        <ExtensionUnit>[
          _unit('web', <String>['web.search']),
        ],
        seeded: <ExtensionUnit>[_engineUnit(handler), _controlUnit(handler)],
      );
      final outcome = await MethodDispatcher(registry)
          .route(MethodCall('nope.go'));

      expect(outcome.isDelivered, isFalse);
      expect(outcome.result, isNull);
      expect(outcome.error!.code, same(JsonRpcErrorCode.methodNotFound));
      expect(outcome.error!.wireCode, -32601);
      expect(
        outcome.error!.code.feedsToModel,
        isFalse,
        reason: 'error-codes.md §1',
      );
      expect(outcome.error!.data['namespace'], 'nope');
      expect(outcome.error!.data['method'], 'nope.go');
      // A literal, not `registry.summary`: the expectation is that the three namespaces are
      // listed **sorted**, which is the reason `summary` sorts at all — a diagnostic that
      // differs between two runs registering the same units in a different order makes the
      // runs indistinguishable in a transcript and not in fact.
      expect(outcome.error!.data['known'], r'$, core, web');
      expect(outcome.body, isA<ErrorBody>());
      expect(outcome.body.toJson().toMap()['error'], isA<JsonMap>());
    });

    test('a handler that throws is -32603 and its data says nothing the exception did', () async {
      // `error-codes.md` §1 lists `-32603` as "Internal error", retry "possible for a transient
      // cause", feed to model "yes" — and §1's `data` channel is the **sanitised** one. The
      // exception's own message is whatever the handler put in it, so a handler that throws
      // `StateError('key sk-… not found')` must not put a credential fragment into a frame a
      // peer reads.
      //
      // The positive control is the point of the second half: the *same* secret, in the *same*
      // namespace, is carried in the `result` of a call that succeeds. A redaction assertion
      // with nothing to leak behind it passes for the wrong reason.
      const secret = 'sk-live-0000';
      final leaky = _FakeHandler(error: 'key $secret not found');
      final registry = _bound(
        <ExtensionUnit>[
          _unit('web', <String>['web.search'], handler: leaky),
        ],
        seeded: <ExtensionUnit>[
          _engineUnit(_FakeHandler()),
          _controlUnit(_FakeHandler()),
        ],
      );
      final dispatcher = MethodDispatcher(registry);

      final ok = await dispatcher.route(
        MethodCall('web.search', params: JsonMap({'apiKey': secret})),
      );
      expect(ok.isDelivered, isTrue);
      expect(
        ok.result!.value['params'],
        isA<JsonMap>(),
        reason: 'the handler saw the credential, so the next assertion has something to lose',
      );
      expect(jsonEncode(ok.result!.value.toEncodable()), contains(secret));

      leaky.failOn.add('web.fetch');
      final thrown = await dispatcher.route(
        MethodCall('web.fetch', params: JsonMap({'apiKey': secret})),
      );
      expect(thrown.isDelivered, isFalse);
      expect(thrown.result, isNull);
      expect(thrown.error!.code, same(JsonRpcErrorCode.internalError));
      expect(thrown.error!.wireCode, -32603);
      expect(
        thrown.error!.code.feedsToModel,
        isTrue,
        reason: 'error-codes.md §1',
      );
      expect(thrown.error!.code.retry, RetryPolicy.onTransientCause);

      // The data names the namespace and the method, and nothing else.
      expect(thrown.error!.data.toMap().keys.toSet(), <String>{
        'namespace',
        'method',
      });
      expect(thrown.error!.data['namespace'], 'web');
      expect(thrown.error!.data['method'], 'web.fetch');

      // Not the message, not in the error object, and not in the bytes a peer would read.
      expect(thrown.error!.message, isNot(contains(secret)));
      expect(thrown.error!.data.toString(), isNot(contains(secret)));
      final wire = jsonEncode(ErrorBody(thrown.error!).toJson().toEncodable());
      expect(
        wire,
        isNot(contains(secret)),
        reason: 'the frame a peer reads:\n$wire',
      );
      expect(
        jsonDecode(wire),
        isA<Map<String, Object?>>(),
        reason: 'and it is real JSON',
      );
    });
  });

  group('the two ownership rules', () {
    test('two owners for one namespace is a bind-time failure with no implicit priority', () {
      // `overview.md` §5: "Registering two owners for the same namespace is a **bind-time
      // failure with no implicit priority**." No winner, no last-registered-wins, no warning.
      final (registry, failures) = ExtensionRegistry.build(<ExtensionUnit>[
        _unit('web', <String>['web.search']),
        _unit('web', <String>['web.other']),
      ]);

      expect(
        registry,
        isNull,
        reason: 'a registry with an arbitrary winner is the failure',
      );
      expect(failures, hasLength(1));
      expect(
        failures.single.code,
        same(ExtensionDiagnosticCode.extensionDuplicateId),
      );
      expect(failures.single.code.code, 'extension.duplicate_id');
      expect(failures.single.path, 'web');
      expect(failures.single.error, 'two owners claim this namespace');
      expect(failures.single.hint, contains('no implicit priority'));
      expect(failures.single.hint, contains('web is already bound'));
    });

    test('two owners for one tool id is the same code, whether or not the units differ', () {
      // `plugins.md` §1: "a tool id has exactly one owner and never two", and `error-codes.md`
      // §3 defines `extension.duplicate_id` as "two units claim one id".
      final (registry, failures) = ExtensionRegistry.build(<ExtensionUnit>[
        _unit('fs', <String>['fs.read', 'fs.write']),
        // A different namespace claiming the same tool id. This is the case that matters: the
        // owner is compared by namespace, so the two units are genuinely different and the
        // collision is not an artefact of one unit listing itself twice.
        _unit('tool', <String>['fs.read']),
      ]);

      expect(registry, isNull);
      expect(failures, hasLength(1));
      expect(failures.single.code.code, 'extension.duplicate_id');
      expect(failures.single.path, 'fs.read');
      expect(failures.single.error, 'two owners claim this tool id');
      expect(failures.single.hint, contains('fs.read is already bound to fs'));
    });

    test(
      'a duplicate tool id inside one unit is refused too, as the same fault',
      () {
        // `ExtensionRegistry._check` documents this in as many words: "the owner is compared by
        // *namespace*, not by unit: a duplicate tool id inside one unit is also a fault, and it
        // is the same fault." The reason it says that is worth repeating: a unit whose tool list
        // names the same id twice is a manifest that disagrees with itself, and `overview.md`
        // §5's "every tool id has one implementation" is false of it.
        //
        // This did not hold. `build` fills its tool map only after `_check` returns, so a
        // duplicate *within* one unit was invisible to the cross-unit loop and the registry bound
        // successfully, keeping the first occurrence and discarding the third — a unit whose own
        // documentation contradicted its behaviour.
        final (registry, failures) = ExtensionRegistry.build(<ExtensionUnit>[
          _unit('fs', <String>['fs.read', 'fs.write', 'fs.read']),
        ]);

        expect(registry, isNull);
        expect(failures, hasLength(1));
        expect(failures.single.code.code, 'extension.duplicate_id');
        expect(failures.single.path, 'fs.read');
        // **A different sentence from the cross-unit case, on purpose.** "two owners claim this
        // tool id" is what the *other* case is — and here there is only one owner, which is the
        // point. A log that said "two owners" for a unit that listed its own tool twice sends the
        // reader looking for a second package that does not exist. Same code, because it is the
        // same fault; different words, because the remedy is different: drop the duplicate line
        // rather than unregister a unit.
        expect(
          failures.single.error,
          isNot('two owners claim this tool id'),
          reason: 'one unit, one owner — "two owners" would name a package that is not involved',
        );
        expect(
          failures.single.error,
          contains('twice'),
          reason: 'and the sentence says what is actually wrong with this one',
        );
        expect(
          failures.single.hint,
          contains('fs.read'),
          reason: 'the hint names the id, so a log line is actionable without the path line',
        );
      },
    );

    test(
      'a tool id in a namespace the unit does not own is config.manifest_drift',
      () {
        // `concepts.md` §2: the dotted prefix is the dispatch key, so `web.search` is routed to
        // `web`. A unit owning `fs` and implementing `web.search` therefore dispatches nowhere —
        // and `error-codes.md` §3's `config.manifest_drift` is "a manifest **parses** but
        // disagrees with the resolved dependency graph", which is exactly this.
        final (registry, failures) = ExtensionRegistry.build(<ExtensionUnit>[
          _unit('fs', <String>['fs.read', 'web.search']),
        ]);

        expect(registry, isNull);
        expect(failures, hasLength(1));
        expect(failures.single.code.code, 'config.manifest_drift');
        expect(
          failures.single.code,
          same(ConfigDiagnosticCode.configManifestDrift),
        );
        expect(failures.single.path, 'web.search');
        expect(
          failures.single.error,
          'declared in a namespace this unit does not own',
        );
        expect(failures.single.hint, contains('web.search is routed to web'));
        expect(failures.single.hint, contains('this unit owns fs'));
      },
    );

    test('a tool id that is not a tool id is config.invalid_schema, naming the grammar', () {
      // `concepts.md` §2's table gives the tool-id grammar, and "an invalid identifier is a
      // configuration error, never a warning". The hint carries the pattern so a reader does
      // not have to open the document to see what was expected.
      for (final bad in <(String, String)>[
        ('websearch', 'one segment has no dot'),
        ('Web.search', 'uppercase is not the grammar'),
        ('web.', 'the trailing segment is empty'),
        ('', 'empty'),
        ('web-search.search', 'a hyphen is not in the grammar'),
        (
          'web.search/variant',
          'a slash is the topic separator, not the tool one',
        ),
        (
          'skill:web_search',
          'the pre-split spelling concepts.md §2.2 replaced',
        ),
      ]) {
        final (registry, failures) = ExtensionRegistry.build(<ExtensionUnit>[
          _unit('web', <String>[bad.$1]),
        ]);
        expect(registry, isNull, reason: bad.$2);
        expect(failures, hasLength(1), reason: bad.$2);
        expect(
          failures.single.code,
          same(ConfigDiagnosticCode.configInvalidSchema),
          reason: '`${bad.$1}`: ${bad.$2}',
        );
        expect(failures.single.path, bad.$1);
        expect(failures.single.error, 'not a tool id');
        expect(failures.single.hint, contains(toolIdGrammar.pattern));
      }

      // And the *positive* side of the same grammar, because a pattern that refused everything
      // would satisfy the loop above: `concepts.md` §2 writes `+` on the trailing group, so
      // three segments are legal and a unit owning `web` may declare one. `error-codes.md` §1's
      // "an invalid identifier is a configuration error" only means something next to a rule
      // about what is valid.
      expect(toolIdGrammar.hasMatch('web.search.now'), isTrue);
      final (built, none) = ExtensionRegistry.build(<ExtensionUnit>[
        _unit('web', <String>['web.search.now']),
      ]);
      expect(none, isEmpty);
      expect(built, isNotNull);
    });

    test('a reserved namespace is a duplicate claim, not a special case', () {
      // `concepts.md` §2.1: a tool, an injection or a plugin "MUST NOT declare a tool or an
      // event topic in a reserved namespace". `namespace.dart` and `registry.dart` both
      // explain how that is held: the registry is *seeded* with `core` and `$` as their first
      // two owners, so an extension claiming either is a second owner for one namespace and
      // reports as exactly that. One rule for one situation, and the hint says it is reserved
      // rather than leaving a reader to work out why their plugin collided with nothing.
      for (final reservedNamespace in reserved) {
        // The namespace object is passed rather than its wire spelling, because
        // `MethodNamespace(r'$')` is a constructor that throws: the throwing factory is for a
        // literal a programmer wrote, and `$` is a valid namespace only as the constant
        // `MethodNamespace.control`. That asymmetry is the control plane's own finding.
        final (registry, failures) = ExtensionRegistry.build(
          <ExtensionUnit>[
            ExtensionUnit(
              namespace: reservedNamespace,
              handler: _FakeHandler(),
              toolIds: const <String>[],
            ),
          ],
          seeded: <ExtensionUnit>[
            _engineUnit(_FakeHandler()),
            _controlUnit(_FakeHandler()),
          ],
        );
        expect(registry, isNull, reason: reservedNamespace.value);
        expect(failures, hasLength(1));
        expect(
          failures.single.code.code,
          'extension.duplicate_id',
          reason: 'a reserved namespace is owned, not special-cased',
        );
        expect(failures.single.path, reservedNamespace.value);
        expect(
          failures.single.hint,
          contains('reserved'),
          reason: 'a reader who collided with the built-in has to be told it was the built-in',
        );
        expect(failures.single.hint, contains('owned by the built-in'));
      }
    });

    test('build reports every refused unit, in registration order, and returns no registry', () {
      // `registry.dart`: "Returns both the registry and **every** refusal, in registration
      // order. A caller that wants to fail on the first can; `plugins.md` §2's `validate` step
      // is a phase, and a phase that sees one fault at a time is a phase run many times." A
      // composition root wiring twenty units wants to know about all four collisions in one
      // run; a `register` that threw would have told it about one and thrown away the other
      // three.
      final (registry, failures) = ExtensionRegistry.build(<ExtensionUnit>[
        // 0: a good unit, so "every failure" cannot be confused with "every unit".
        _unit('ok', <String>['ok.go']),
        // 1: two faults in one unit. `_check` returns on the first, by its own stated
        //    ordering — "in the order that gives the most useful diagnostic when more than one
        //    is broken" — so this unit contributes one failure, not two.
        _unit('web', <String>['websearch', 'fs.read']),
        // 2: a second owner of `web`. See the note below on why this is *not* reported.
        _unit('web', <String>['web.other']),
        // 3: another fault, later in the list than 1.
        _unit('bad', <String>['bad.go', 'nope']),
      ]);

      expect(registry, isNull);
      expect(
        failures
            .map((failure) => '${failure.code.code}@${failure.path}')
            .toList(),
        <String>[
          'config.invalid_schema@websearch',
          'config.invalid_schema@nope',
        ],
        reason:
            'registration order, one failure per refused unit, and the two that are clean '
            'contribute nothing',
      );

      // An observation rather than a requirement, and asserted as its own thing rather than
      // smoothed into the count above: a unit refused for a *tool id* is never added to the
      // namespace map, so a later unit claiming the same namespace is not itself reported as
      // a duplicate. No winner was picked either way — the bind failed — but the diagnostic
      // list is shorter than the number of colliding `register` calls, and a reader comparing
      // it against their own wiring deserves to know that is why.
      expect(
        failures.where((f) => f.error.contains('namespace')).toList(),
        isEmpty,
        reason: 'unit 2 claimed a namespace unit 1 was refused for, so nothing was bound to it',
      );
    });

    test('a registry built without the seed does not own core, and says so per call', () async {
      // `build` documents that the seeded units are validated with the same rule as the
      // extensions, "so a caller that forgets to seed them gets the same answer for `core` as
      // for a duplicated plugin, rather than a second code for the same situation." The
      // observable consequence is that a core built this way has *two* shapes for a
      // `core/` method: refused with `-32601` here, and refused with `-32042` for a
      // capability granted after a handshake. The first is the bind's mistake to fix.
      final registry = _bound(<ExtensionUnit>[
        _unit('web', <String>['web.search']),
      ]);
      expect(registry.owns(MethodNamespace.core), isFalse);
      expect(registry.owns(MethodNamespace.control), isFalse);
      expect(registry.namespaces.map((n) => n.value).toList(), <String>['web']);

      final outcome = await MethodDispatcher(registry)
          .route(MethodCall('core/run'));
      expect(outcome.error!.wireCode, -32601);
      expect(outcome.error!.data['known'], 'web');
    });

    test('a registration outcome carries a printable diagnostic for the same path', () {
      // `RegistrationOutcome.diagnostic` exists so a bind-time refusal reaches the operator
      // through the reporting path a configuration fault already uses — `doctor
      // --validate-config` prints diagnostics, and a registry fault that cannot be printed is
      // a fault the operator debugs from a stack trace.
      final (_, failures) = ExtensionRegistry.build(<ExtensionUnit>[
        _unit('web', <String>['websearch']),
      ]);
      final outcome = RegistrationOutcome(
        accepted: false,
        failure: failures.single,
      );
      final diagnostic = outcome.diagnostic!;
      expect(diagnostic.code.code, 'config.invalid_schema');
      expect(diagnostic.path, 'websearch');
      expect(diagnostic.values['field'], 'websearch');
      expect(diagnostic.values['expected'], failures.single.hint);
      // The diagnostic carries the hint, never a sentence assembled at the call site — that is
      // `configuration.md` §7.2, and it is why there is no `error:` parameter to fill in.
      expect(diagnostic.values.keys, isNot(contains('error')));

      expect(RegistrationOutcome(accepted: true).diagnostic, isNull);
      expect(RegistrationOutcome(accepted: true).failure, isNull);
    });
  });

  group('notifications', () {
    test(
      'routeNotification reports whether an owner took it, and never throws',
      () async {
        // The §5 table is not only about requests. `$/cancelRequest` and `$/progress` are
        // notifications — no `id`, no response owed — and a dispatcher that routed only
        // `MethodCall` would leave the control plane unreachable. `routeNotification` returns a
        // `bool` and nothing else: "a notification is one-way and a handler that produces one has
        // been asked the wrong question".
        final owner = _FakeHandler();
        final thrower = _FakeHandler(error: 'key sk-live-0000 not found')
          ..failOn.add('boom/go');
        final registry = _bound(
          <ExtensionUnit>[
            _unit('web', <String>['web.search'], handler: owner),
            _unit('boom', const <String>[], handler: thrower),
          ],
          seeded: <ExtensionUnit>[
            _engineUnit(_FakeHandler()),
            _controlUnit(_FakeHandler()),
          ],
        );
        final dispatcher = MethodDispatcher(registry);

        // Taken: the owner saw it, with its params, and the answer to "did an owner take it" is
        // the whole of what the caller can act on.
        final taken = await dispatcher.routeNotification(
          _notification('web', 'web/progress', params: JsonMap({'n': 1})),
        );
        expect(taken, isTrue);
        expect(owner.seen, <String>['web/progress']);

        // Not taken: a namespace nobody owns. `error-codes.md` §3.1's control-plane rules make
        // an unknown `$/cancelRequest` a non-event, and this is the same shape — "a frame nobody
        // owns is a frame nobody sent on purpose, and turning it into a protocol error would fail
        // a healthy session over it."
        expect(
          await dispatcher.routeNotification(_notification('nope', 'nope/go')),
          isFalse,
        );
        // A method that does not begin with a namespace is simply a notification nobody owns.
        // The dispatcher's no-op sentinel is gone, and its comment says why: "a private
        // namespace whose `value` was the empty string is a fake value in a type whose whole
        // job is to be a parsed one". The frame's `module` here is `core`, which *is* bound —
        // so the refusal is about the method and not about the frame, and a reader who fixed
        // only the module would still get `false`.
        expect(
          await dispatcher.routeNotification(
            _notification('core', '/leading-slash'),
          ),
          isFalse,
        );
        expect(
          await dispatcher.routeNotification(
            _notification('core', 'Upper/case'),
          ),
          isFalse,
        );

        // Not taken, and not thrown: a handler that threw on a one-way frame has no one to
        // answer, and rethrowing would fail a session over a notification that was never owed a
        // response. The bool cannot carry the cause — "a bool that pretends to carry a cause is
        // worse than one that does not" — so the caller is expected to have logged it.
        expect(
          await dispatcher.routeNotification(_notification('boom', 'boom/go')),
          isFalse,
        );
        expect(thrower.seen, <String>['boom/go']);
      },
    );

    test(
      'the two control-plane method names parse to the control namespace',
      () {
        // The root cause of `$/`'s reachability, isolated so a failure here names the parse
        // rather than the routing. `MethodNamespace.control` is `r'$'` and the two methods are
        // `$/cancelRequest` and `$/progress` — but `$` is not a leading `[a-z][a-z0-9_]*` run, so
        // `namespaceGrammar` cannot produce it, and `namespace.dart` calls `control` "the one
        // namespace that is not a word, which is why [reserved] is a list and not a range".
        //
        // §5's second row and `concepts.md` §2.1's second reservation both need the two names
        // to resolve to it, and the shipped handshake needs `core.initialize` — which does
        // resolve, because `core` *is* a word. So the two reserved namespaces are in
        // different states, and the one that is not a word is the one that cannot be reached.
        expect(MethodNamespace.control.value, r'$');
        expect(cancelRequestMethod, r'$/cancelRequest');
        expect(progressMethod, r'$/progress');
        expect(initializeMethod, 'core.initialize');
        expect(
          MethodNamespace.of(cancelRequestMethod),
          MethodNamespace.control,
          reason: r'concepts.md §2.1 reserves `$/` for `alteri_one_protocol`',
        );
        expect(MethodNamespace.of(progressMethod), MethodNamespace.control);
        expect(MethodNamespace.of(initializeMethod), MethodNamespace.core);
      },
    );

    test(
      'the seeded control plane takes \$/cancelRequest and \$/progress',
      () async {
        // §5's second row, with the two method names `alteri_one_protocol` declares rather than
        // strings written here: `cancelRequestMethod` and `progressMethod`. If the two spellings
        // ever disagree, this stops being a test of routing and starts being a test of a typo.
        final control = _FakeHandler();
        final registry = _bound(
          <ExtensionUnit>[
            _unit('web', <String>['web.search']),
          ],
          seeded: <ExtensionUnit>[
            _engineUnit(_FakeHandler()),
            _controlUnit(control),
          ],
        );
        final dispatcher = MethodDispatcher(registry);

        // `MethodCall` first, because it is the narrower claim and it fails first if the
        // namespace is unreachable: the constructor parses the method through the same
        // `MethodNamespace.of` the dispatcher uses, and refuses a method that has no namespace.
        expect(
          () => MethodCall(cancelRequestMethod),
          returnsNormally,
          reason: 'a control-plane notification is a method like any other to the parser',
        );

        expect(
          await dispatcher.routeNotification(
            _notification(r'$', cancelRequestMethod),
          ),
          isTrue,
          reason:
              r'overview.md §5: `$/` is routed to the protocol control plane',
        );
        expect(
          await dispatcher.routeNotification(
            _notification(r'$', progressMethod),
          ),
          isTrue,
        );
        expect(control.seen, <String>[cancelRequestMethod, progressMethod]);
        expect(control.operations, <String>['cancelRequest', 'progress']);
      },
    );
  });

  group('the mandatory envelope', () {
    test('every event carries §4\'s eleven members, and a root omits the twelfth', () {
      // `engine.md` §4: "Every event carries at least `eventId`, `traceId`, `spanId`,
      // `parentSpanId`, `timestamp`, `eventType`, `profile`, `projectId`, `provenance`,
      // `schemaVersion` and a redacted payload."
      //
      // Read as a *minimum* — which is what "at least" means — that is a floor on what a
      // record carries and not a licence for a member to be optional. So the constructor takes
      // ten named required arguments and the eleventh as a [SpanParent] of type [RootSpan] or
      // [ChildSpan] rather than as a `String?`, and this test checks the **key set** rather
      // than eleven individual members, because a key set catches a member that was added and
      // one that was dropped in the same assertion.
      final root = _event();
      expect(root.toJson().toMap().keys.toSet(), <String>{
        'eventId',
        'eventType',
        'spanId',
        'traceId',
        'timestamp',
        'profile',
        'projectId',
        'provenance',
        'schemaVersion',
        'payload',
      });

      // A root **omits** `parentSpanId` rather than writing null. The reason is
      // `EventEnvelope.metaToJson`'s and the observation protocol's: a peer receiving
      // `parentSpanId: null` has to decide whether that means "no parent" or "the sender did
      // not know", and the specification does not make it say. [RootSpan] is an unambiguous
      // absence and the omission is what carries that across.
      expect(root.isRoot, isTrue);
      expect(root.parent, isA<RootSpan>());
      expect(root.parentSpanId, isNull);
      expect(
        root.toJson().containsKey('parentSpanId'),
        isFalse,
        reason: 'a null is a value a reader has to interpret; an absent member is not',
      );

      final child = _event(
        id: 'evt_00000002',
        type: EventType.stepCompleted,
        parentSpanId: root.spanId,
      );
      expect(child.isRoot, isFalse);
      expect(child.parent, isA<ChildSpan>());
      expect(child.parentSpanId, root.spanId);
      expect(child.toJson().toMap().keys.toSet(), <String>{
        ...root.toJson().toMap().keys,
        'parentSpanId',
      });
      expect(child.toJson()['parentSpanId'], root.spanId);

      // The remaining members, read back as the values that went in — the "at least" claim is
      // about presence, and presence alone would be satisfied by a record of eleven nulls.
      final json = root.toJson();
      expect(json['eventId'], 'evt_00000001');
      expect(json['eventType'], 'task_started');
      expect(json['spanId'], 'span_00000001');
      expect(json['traceId'], 'trace_9f2c41ab');
      expect(json['profile'], 'companion');
      expect(json['projectId'], 'proj_0a1b2c3d');
      expect(json['provenance'], 'user_stated');
      expect(json['schemaVersion'], eventSchemaVersion);
      expect(json['schemaVersion'], 1);
      expect(json['payload'], isA<JsonMap>());

      // `overview.md` §6's "All events flow on one bus carrying `traceId`" is a type and not a
      // convention here: `traceId` is non-nullable on the record even though
      // `EventEnvelope.traceId` is optional, and a reader holding an `AlteriOneEvent` cannot
      // reach a branch where it is absent.
      expect(root.traceId, isNotEmpty);
      expect(root.toEnvelope(meta: _meta).traceId, root.traceId);
    });

    test('the timestamp is rendered fixed-width and the toString carries no payload', () {
      // `observability.md` §2 wants a fixed canonical form, and `event.dart` says both halves
      // of the rendering matter: UTC so a record written in one zone byte-compares with one
      // written in another, and truncation to milliseconds so the field's width does not depend
      // on the platform clock's resolution (`toIso8601String` drops the fractional part when
      // it is zero and keeps six digits when it is not).
      // `DateTime.utc` takes microseconds as a whole, not as a fraction, so a sub-millisecond
      // instant is built by adding. The point is that the *rendering* truncates it, which is
      // the width `observability.md` §2 asks for.
      final wide = _event(
        timestamp: DateTime.utc(
          2026,
          1,
          2,
          3,
          4,
          5,
          678,
        ).add(const Duration(microseconds: 900)),
      );
      final whole = _event(
        id: 'evt_00000003',
        timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      final local = _event(
        id: 'evt_00000004',
        timestamp: DateTime(2026, 1, 2, 3, 4, 5),
      );

      expect(wide.canonicalTimestamp, '2026-01-02T03:04:05.678Z');
      expect(
        whole.canonicalTimestamp,
        '2026-01-02T03:04:05.000Z',
        reason:
            'a zero millisecond is rendered, not dropped — the width is fixed',
      );
      expect(
        local.canonicalTimestamp,
        whole.canonicalTimestamp,
        reason: 'a local instant and its UTC twin render identically',
      );
      expect(wide.toJson()['timestamp'], '2026-01-02T03:04:05.678Z');

      // `toString` prints the type and the id and nothing else. An event's payload is where a
      // tool's arguments and a model turn's text live, and a `toString` that rendered the
      // record would put both into every crash report, every failed `expect` and every
      // `print` a test leaves behind.
      final secretish = _event(
        id: 'evt_00000005',
        payload: RedactedPayload.of(
          JsonMap({'apiKey': 'sk-live-0000'}),
          sensitivity: Sensitivity.privateData,
          redactor: (raw, _) => raw,
        ),
      );
      expect(secretish.toString(), 'AlteriOneEvent(task_started evt_00000005)');
      expect(secretish.toString(), isNot(contains('sk-live-0000')));
      expect(secretish.toString(), isNot(contains('span_00000001')));
      expect(secretish.payload.toString(), 'RedactedPayload(1 member(s))');
      expect(secretish.payload.toString(), isNot(contains('sk-live-0000')));
    });

    test('an event becomes an EventEnvelope on a qualified topic and encodes to real JSON', () {
      // `concepts.md` §2's event topic is `core/<eventType>` and §2.1 reserves `core/` for the
      // engine's own methods, so the module is the `core` namespace the registry has already
      // seeded an owner for. The topic is qualified, the name is not: a user writing
      // `notifications: - event: task_done` in `alterione.yaml` names the event, and the
      // namespace is added in one member and nowhere else.
      for (final type in EventType.values) {
        expect(type.topic, 'core/${type.wireName}');
        expect(
          eventTopicGrammar.hasMatch(type.topic),
          isTrue,
          reason:
              '${type.wireName}: every topic this build produces is two segments',
        );
        expect(EventType.fromWireName(type.topic), same(type));
        expect(EventType.fromWireName(type.wireName), same(type));
      }
      expect(
        EventType.values.map((type) => type.wireName).toList(),
        <String>[
          'task_started',
          'plan_ready',
          'step_started',
          'tool_call',
          'step_completed',
          'task_done',
          'subagent_done',
          'compacted',
        ],
        reason:
            'engine.md §4 lists these eight, in this order, and nothing else',
      );
      expect(EventType.fromWireName('step_complete'), isNull);
      expect(EventType.fromWireName(7), isNull);

      final event = _event();
      final envelope = event.toEnvelope(meta: _meta);
      expect(envelope, isA<EventEnvelope>());
      expect(envelope.type, EnvelopeType.event);
      expect(envelope.module, MethodNamespace.core.value);
      expect(envelope.topic, EventType.taskStarted.topic);
      expect(envelope.traceId, event.traceId);
      expect(envelope.data, event.toJson());
      // There is no `id`: an event is one-way and expects no answer, and an id would imply one
      // was owed. The constructor has no `id` parameter, which is the specification's "a
      // notification has no `id`" as a signature.
      expect(envelope.id, isNull);

      // `encodeFrame` rather than `jsonEncode(envelope.toJson())`: a `JsonMap` is a wrapper,
      // so `dart:convert` does not look inside it and the direct call fails at the first nested
      // value. The successful encode *is* the assertion.
      final encoded = encodeFrame(envelope);
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(decoded['type'], 'event');
      expect(decoded['module'], 'core');
      expect(decoded['topic'], 'core/task_started');
      expect(decoded['traceId'], 'trace_9f2c41ab');
      expect(decoded['jsonrpc'], '2.0');
      final data = decoded['data'] as Map<String, Object?>;
      expect(data['eventId'], 'evt_00000001');
      expect(data['eventType'], 'task_started');
      expect(data.keys, isNot(contains('parentSpanId')));
    });

    test('a secret payload is refused, and a caller cannot build a payload without a redactor', () {
      // `concepts.md` §3.1 is unconditional: "`secret` content MUST NOT be written to memory,
      // transcript, logs, argv, or a manifest, **even in debug mode**." An event record is
      // written to all five, so `RedactedPayload.of` refuses rather than redacting and
      // publishing the result — "a 'redacted' secret is still a secret that was handled by a
      // routine nobody reviewed".
      expect(
        () => RedactedPayload.of(
          JsonMap({'apiKey': 'sk-live-0000'}),
          sensitivity: Sensitivity.secret,
          redactor: (raw, _) => raw,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('secret'), contains('concepts.md §3.1')),
          ),
        ),
      );

      // The refusal is on the *declared sensitivity*, not on the content: a payload that
      // happens to contain a key is fine as private data, which is what a redactor is for.
      // The redactor is applied, and applied with the sensitivity it was given, so a caller
      // cannot skip the step by passing a function that ignores it — there is no way to tell
      // from the argument alone, and that is the point: it is a *visible* choice in a diff.
      final applied = <Sensitivity>[];
      final payload = RedactedPayload.of(
        JsonMap({'apiKey': 'sk-live-0000', 'path': '/home/x/.ssh/id_rsa'}),
        sensitivity: Sensitivity.privateData,
        redactor: (raw, sensitivity) {
          applied.add(sensitivity);
          return JsonMap({'redacted': true, 'keys': raw.value.keys.toList()});
        },
      );
      expect(applied, <Sensitivity>[Sensitivity.privateData]);
      expect(payload.value['redacted'], isTrue);
      expect(
        (payload.value['keys']! as JsonList).toList(),
        <String>['apiKey', 'path'],
        reason: 'a `JsonMap` value is a `JsonList`, and it is a JSON array rather than a Set',
      );
      expect(payload.value.toString(), isNot(contains('sk-live-0000')));
      expect(payload.value.toString(), isNot(contains('id_rsa')));

      // `RedactedPayload` has a private constructor and one public door that takes a
      // redactor, so a payload cannot be obtained by *forgetting* to redact. The second half
      // of that is a **signature** and not a check this file can perform: `redactor` is a
      // required named parameter, so `RedactedPayload.of(raw, sensitivity: s)` does not
      // compile. A property the compiler holds is stronger than a property a test asserts, so
      // what is asserted here is the other half — that `empty` is the only other producer and
      // that it carries nothing.
      expect(RedactedPayload.empty.value, JsonMap.empty);
      expect(
        RedactedPayload.empty.value.toMap(),
        isEmpty,
        reason: 'engine.md §4\'s "at least" is a floor: task_started carries no payload',
      );
      for (final sensitivity in Sensitivity.values) {
        expect(
          Sensitivity.fromWireName(sensitivity.wireName),
          same(sensitivity),
          reason: '§3.1: labels survive serialisation unchanged',
        );
      }
      expect(Sensitivity.fromWireName('private'), isNull);
      expect(Sensitivity.fromWireName(3), isNull);
    });

    test('the seven labels of concepts.md §3 win over the five words of engine.md §4', () {
      // The two documents do not reconcile, and `event.dart` records the conflict and the
      // decision rather than picking one silently. `concepts.md` §3's seven are the settled
      // taxonomy — ADR-0005's *Forbidden* list names "a second label enum anywhere", and
      // §3.1 requires that a label survive transport unchanged, which a coarse event label
      // would have to be *mapped* to reach.
      expect(
        Provenance.values.map((value) => value.wireName).toList(),
        <String>[
          'user_stated',
          'system_generated',
          'model_inferred',
          'tool_observed',
          'web_content',
          'skill_content',
          'mcp_tool_output',
        ],
        reason: 'concepts.md §3, in the order that document gives them',
      );
      for (final value in Provenance.values) {
        expect(
          Provenance.fromWireName(value.wireName),
          same(value),
          reason:
              'a label that changes value across a boundary is a bug (§3.1)',
        );
      }
      expect(Provenance.fromWireName('plugin'), isNull);
      expect(Provenance.fromWireName(null), isNull);
      expect(Provenance.fromWireName(1), isNull);

      // The mapping is four entries and one absence, and the absence is the decision.
      expect(Provenance.engineSources, hasLength(4));
      expect(Provenance.engineSources, <String, Provenance>{
        'host': Provenance.systemGenerated,
        'user': Provenance.userStated,
        'model': Provenance.modelInferred,
        'tool': Provenance.toolObserved,
      });
      expect(Provenance.fromWord('host'), Provenance.systemGenerated);
      expect(
        Provenance.fromWord('plugin'),
        isNull,
        reason: 'the one coarse word with no value',
      );
      expect(
        Provenance.fromWord('Plugin'),
        isNull,
        reason: 'the coarse words come out of prose, and the match is exact',
      );

      // A plugin is host-supplied code, so the honest label for its content is
      // `systemGenerated` — but a caller has to *say* it wants that, by reaching for a named
      // constant, rather than having a fifth map entry make the decision for them. A map entry
      // would have turned "plugin content is host content" into a lookup, and
      // `concepts.md` §3's two plugin-shaped labels — an MCP server's output and a skill pack's
      // body — are the other two answers.
      expect(Provenance.pluginSource, Provenance.systemGenerated);
      expect(
        Provenance.engineSources.containsKey('plugin'),
        isFalse,
        reason: 'the absence is the whole of §3\'s conflict section; a reader must see it',
      );
      expect(Provenance.mcpToolOutput.wireName, 'mcp_tool_output');
      expect(Provenance.skillContent.wireName, 'skill_content');
    });
  });

  group('the one bus', () {
    test('a subscriber sees the types it asked for, in subscription order', () {
      // `overview.md` §6: "All events flow on one bus carrying `traceId`". The bus is a
      // synchronous in-process fan-out, and the order is **subscription order** — not the
      // event's id (the counters are per kind, so there is no total order over events), not the
      // topic (a plugin's `tool_call` completes before the `task_started` that began it), and
      // not a hash order (which would make a transcript's order a function of the alphabet).
      // `observability.md` §2 compares transcripts byte for byte, and byte-for-byte is not a
      // property a scheduler can be asked for.
      final bus = EventBus();
      final seen = <String>[];
      final started = bus.subscribe(
        EventType.taskStarted,
        (e) => seen.add('first:${e.eventId}'),
      );
      final both = bus.subscribeTo(
        <EventType>{EventType.taskStarted, EventType.taskDone},
        (e) {
          seen.add('both:${e.eventId}');
        },
      );
      final done = bus.subscribe(
        EventType.taskDone,
        (e) => seen.add('third:${e.eventId}'),
      );
      expect(bus.subscriberCount, 3);
      expect(<int>[started.id, both.id, done.id], <int>[0, 1, 2]);
      expect(started.types, <EventType>{EventType.taskStarted});
      expect(both.types, <EventType>{
        EventType.taskStarted,
        EventType.taskDone,
      });

      bus.publish(_event());
      bus.publish(_event(id: 'evt_00000002', type: EventType.taskDone));

      // The event the third subscriber did not ask for reaches the second and stops there.
      expect(seen, <String>[
        'first:evt_00000001',
        'both:evt_00000001',
        'both:evt_00000002',
        'third:evt_00000002',
      ]);

      // `publish` is synchronous: when it returns, every live subscriber has run, and the bus
      // does not import `dart:async` at all. A microtask boundary here would make the order a
      // function of the event loop's.
      expect(bus.failures, isEmpty);
      expect(
        seen,
        hasLength(4),
        reason: 'no await has happened since the publishes',
      );
    });

    test(
      'unsubscribe is idempotent, immediate, and it clears the observable',
      () async {
        // The two halves are separate and both are load-bearing. **Idempotent**, because
        // `unsubscribe` is what a `finally` block calls and a teardown that throws on its
        // second call replaces the error it was cleaning up after. **Immediate**, including for
        // an event currently being delivered: if an earlier subscriber in the same `publish`
        // released a later one, the released one does not receive the event it was released
        // during. **Cleared rather than merely cancelled**, because the bus walks its list
        // during a delivery and an observable that is briefly wrong is worse than one that is
        // absent.
        final bus = EventBus();
        final seen = <String>[];
        // The handle the first subscriber releases, reached through a one-element holder rather
        // than through a forward reference to a `final` declared below it: a closure that
        // captures a local the analyzer cannot prove is assigned is reported, and the
        // interesting property here is that a *release during a delivery* takes effect at once.
        final released = <EventSubscription>[];
        final first = bus.subscribe(EventType.taskStarted, (e) {
          seen.add('first');
          released.single.unsubscribe();
        });
        final second = bus.subscribe(
          EventType.taskStarted,
          (e) => seen.add('second'),
        );
        released.add(second);
        expect(second.isActive, isTrue);

        bus.publish(_event());
        expect(
          seen,
          <String>['first'],
          reason:
              'a release is a statement about now, not about the next publish',
        );
        expect(second.isActive, isFalse);

        // A second call is a no-op rather than a throw.
        second.unsubscribe();
        second.unsubscribe();
        expect(second.isActive, isFalse);
        expect(bus.subscriberCount, 1);

        bus.publish(_event(id: 'evt_00000002'));
        expect(seen, <String>['first', 'first']);
        expect(first.isActive, isTrue);

        // A subscription taken during a publish does not receive the event in flight: the bus
        // walks a snapshot, so "publish reached everyone who was listening" is a statement a
        // reader can check with no exceptions to remember.
        final snapshotBus = EventBus();
        final snapshotSeen = <String>[];
        snapshotBus.subscribe(EventType.taskStarted, (e) {
          snapshotSeen.add('outer');
          snapshotBus.subscribe(EventType.taskStarted, (e) {
            snapshotSeen.add('inner');
          });
        });
        snapshotBus.subscribe(EventType.taskStarted, (e) {
          snapshotSeen.add('after');
        });
        snapshotBus.publish(_event());
        expect(snapshotSeen, <String>[
          'outer',
          'after',
        ], reason: 'and not `inner`');
        snapshotBus.publish(_event(id: 'evt_00000002'));
        expect(snapshotSeen, <String>[
          'outer',
          'after',
          'outer',
          'after',
          'inner',
        ]);
      },
    );

    test(
      'a subscriber that throws does not starve the next one, and is recorded',
      () {
        // `error-codes.md` §3's `engine.observer_failed`: "A subscriber on the event bus threw
        // while being delivered an event. Isolated: the remaining subscribers still receive the
        // event, the throw is recorded against the subscription, and the run continues. It is a
        // **log** code, never a refusal — an observer is not enforcement, so there is nothing
        // here to refuse *about*."
        //
        // **Not swallowing** is the half that is easy to get wrong: a loop that let a throw
        // escape would starve every subscriber after it *silently* — the second observer would
        // stop seeing events and nothing would turn red, which is worse than a crash.
        final bus = EventBus();
        final seen = <String>[];
        final before = bus.subscribe(
          EventType.taskStarted,
          (e) => seen.add('before'),
        );
        final thrower = bus.subscribe(
          EventType.taskStarted,
          (e) => throw StateError('key sk-live-0000 not found'),
        );
        final after = bus.subscribe(
          EventType.taskStarted,
          (e) => seen.add('after'),
        );

        bus.publish(_event());
        expect(seen, <String>[
          'before',
          'after',
        ], reason: 'the loop continued past the thrower');
        expect(bus.failures, hasLength(1));
        expect(thrower.isActive, isTrue, reason: 'a failure is not a release');

        final failure = bus.failures.single;
        expect(failure.code, same(EngineDiagnosticCode.engineObserverFailed));
        expect(failure.code.code, 'engine.observer_failed');
        expect(failure.subscriptionId, thrower.id);
        expect(failure.event.eventId, 'evt_00000001');
        expect(failure.error, isA<StateError>());
        expect(failure.stackTrace, isNotNull);

        // The failure report renders the event through `toString`, which prints the type and the
        // id and not the payload — a failure report is written to a log, and a payload printed
        // into one is a payload in a transcript.
        expect(failure.toString(), contains('engine.observer_failed'));
        expect(failure.toString(), contains('subscription ${thrower.id}'));
        expect(failure.toString(), contains('task_started'));
        expect(failure.toString(), isNot(contains('sk-live-0000')));

        // The diagnostic carries the code, the subscription and the event type, and **not** the
        // subscriber's own message: `error-codes.md` §1's `data` channel is the sanitised one,
        // and a subscriber that throws `StateError('key sk-… not found')` would otherwise put a
        // credential fragment into a message an operator reads.
        final diagnostic = failure.toDiagnostic('en');
        expect(diagnostic.code.code, 'engine.observer_failed');
        expect(diagnostic.path, 'eventBus.subscriptions[${thrower.id}]');
        expect(diagnostic.values['field'], 'task_started');
        expect(diagnostic.values.keys, isNot(contains('error')));
        final rendered = diagnostic.render('en');
        expect(rendered, contains('engine.observer_failed'));
        expect(rendered, isNot(contains('sk-live-0000')));
        // And it is localised, like every other diagnostic.
        expect(diagnostic.render('ru'), isNotEmpty);
        expect(diagnostic.render('ru'), isNot(contains('sk-live-0000')));

        // `before` and `after` are still attached: a throw is a record, not a release.
        expect(before.isActive, isTrue);
        expect(after.isActive, isTrue);
        expect(bus.droppedFailures, 0);
        // `failures` hands out a copy, so a reader cannot clear the record. A bus whose failure
        // history a caller can mutate is not the record this class documents.
        expect(() => bus.failures.add(failure), throwsUnsupportedError);
        expect(bus.failures, hasLength(1));
      },
    );

    test('the recorded failures are bounded, and the count of what was dropped is not', () {
      // A cap rather than a policy: a broken observer in a long run is exactly when the list
      // is growing, and 64 is small enough that a full bus's memory is measured in kilobytes.
      // `droppedFailures` is separate so that "there were 65 failures" and "there were 65 and
      // I can see one" cannot be confused — a cap that silently discarded records would let a
      // permanently broken observer look like an intermittently broken one.
      expect(EventBus.maxRecordedFailures, 64);

      final bus = EventBus();
      bus.subscribe(
        EventType.taskStarted,
        (e) => throw StateError('observer broke'),
      );
      for (var index = 0; index < 65; index++) {
        bus.publish(
          _event(id: 'evt_${index.toRadixString(16).padLeft(8, '0')}'),
        );
      }

      expect(bus.failures, hasLength(EventBus.maxRecordedFailures));
      expect(bus.droppedFailures, 1);
      // The **oldest** went, so the evidence a reader wants is the most recent run.
      expect(bus.failures.first.event.eventId, 'evt_00000001');
      expect(bus.failures.last.event.eventId, 'evt_00000040');
      expect(
        bus.failures.every(
          (failure) => failure.code.code == 'engine.observer_failed',
        ),
        isTrue,
      );
    });

    test('close is idempotent, it releases the subscriptions, and it refuses what follows', () {
      // `close` is what a `finally` block calls, so a teardown that throws on its second call
      // replaces the error it was cleaning up after. It **releases** the subscriptions rather
      // than leaving them attached, because a handle held past `close` would report
      // `isActive` as true and promise deliveries that cannot happen.
      final bus = EventBus();
      final seen = <String>[];
      final subscription = bus.subscribe(
        EventType.taskStarted,
        (e) => seen.add('delivered'),
      );
      bus.subscribe(EventType.taskDone, (e) => seen.add('delivered'));
      // One failure recorded before the close, so "the record survives the teardown" is a
      // statement about a non-empty list rather than a statement about nothing.
      bus.subscribe(
        EventType.taskStarted,
        (e) => throw StateError('observer broke'),
      );
      bus.publish(_event());
      expect(bus.failures, hasLength(1));
      expect(seen, <String>['delivered']);
      expect(bus.isClosed, isFalse);

      bus.close();
      expect(bus.isClosed, isTrue);
      expect(bus.subscriberCount, 0);
      expect(subscription.isActive, isFalse);
      bus.close();
      expect(bus.isClosed, isTrue);

      // A subscription taken after teardown would "look active and never be delivered to".
      expect(
        () => bus.subscribe(EventType.taskStarted, (e) {}),
        throwsA(isA<StateError>()),
      );
      expect(
        () => bus.subscribeTo(<EventType>{EventType.taskDone}, (e) {}),
        throwsStateError,
      );

      // And publishing after teardown is a `StateError` rather than a silent no-op, because
      // `engine.md` §4 makes the terminal event of a run the one that must never be dropped:
      // a no-op would end a transcript with no terminal record and an exit code of 0.
      expect(() => bus.publish(_event()), throwsA(isA<StateError>()));
      expect(
        () => bus.publish(_event(type: EventType.taskDone)),
        throwsStateError,
      );
      expect(
        () => bus.publish(_event(id: 'evt_00000009', type: EventType.taskDone)),
        throwsA(
          isA<StateError>()
              .having(
                (error) => error.message,
                'message',
                contains('task_done'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('evt_00000009'),
              ),
        ),
        reason:
            'the message names the event that was refused, by type and by id',
      );
      expect(
        seen,
        <String>['delivered'],
        reason:
            'the one delivery is the one made before the close, and no other',
      );

      // The recorded failures survive the close. They are about observers that already failed,
      // and a teardown that erased the evidence would be the last thing to go.
      expect(bus.failures, hasLength(1));
      expect(bus.failures.single.event.eventId, 'evt_00000001');
      expect(bus.droppedFailures, 0);
    });

    test('a subscription to no event type is an ArgumentError', () {
      // A subscription that can never be called is a wiring mistake, and it would otherwise be
      // indistinguishable from one wired to the wrong type — except that a misspelled type is
      // a compile error here, which is the whole benefit of taking the enum. There is no
      // wildcard and no predicate: `config-schema.md` §2 configures notifications as
      // `- event: task_done` with no pattern, and a filter language here would be a second
      // vocabulary with nothing in the specification behind it.
      final bus = EventBus();
      expect(() => bus.subscribeTo(<EventType>{}, (e) {}), throwsArgumentError);
      expect(bus.subscriberCount, 0);
      expect(
        EventType.values,
        hasLength(8),
        reason: 'eight do not need a filter language',
      );
    });
  });

  group('the documents the code answers to', () {
    test(
      'overview.md §5\'s table is the three rows the dispatcher is built for',
      () {
        // Parsed, not restated. A copy of a table is a second table, and the two documents would
        // agree until the day somebody edited one of them.
        final rows = _documentedDispatchPrefixes(_repositoryRoot());
        expect(
          rows,
          <String>['core/*', r'$/', '<namespace>.*'],
          reason: '§5 names three rows, in that order, and the third is the load-bearing one',
        );
        // The two reserved rows are matched against the namespaces the code spells, by value:
        // a `$` written `dollar` in `namespace.dart` and `$/` in the document would produce the
        // same document and a different namespace.
        expect(rows[0], '${MethodNamespace.core.value}/*');
        expect(rows[1], '${MethodNamespace.control.value}/');
        expect(
          MethodNamespace.core.isReserved && MethodNamespace.control.isReserved,
          isTrue,
        );
        expect(MethodNamespace('web').isReserved, isFalse);
        expect(
          reserved,
          hasLength(2),
          reason: '§2.1 reserves exactly two method prefixes',
        );
      },
    );

    test(
      'concepts.md §2.1\'s reserved prefixes are the ones the code holds',
      () {
        final documented = _documentedReservations(_repositoryRoot());
        expect(
          documented.methods.toSet(),
          reserved.map((namespace) => '${namespace.value}/').toSet(),
          reason: r'§2.1 reserves `core/` for the engine and `$/` for the control plane',
        );
        expect(
          documented.ids.toSet(),
          reservedIdPrefixes.toSet(),
          reason:
              '§2.1 reserves the six `trace_`, `req_`, `span_`, `evt_`, `mem_`, `art_` prefixes '
              'for `IdGenerator`',
        );
        expect(
          documented.ids,
          hasLength(reservedIdPrefixes.length),
          reason: 'and there are no others',
        );

        // The gap this file records rather than asserts away. `namespace.dart` says "a namespace
        // must not be one of them" and gives the reason — "a package named `trace_` would
        // otherwise be registrable and its ids would be indistinguishable from a record id in a
        // log" — and the grammar it points at is `^[a-z][a-z0-9_]*`, in which `_` is legal after
        // a letter. So **every** reserved id prefix is also a legal namespace, and
        // `ExtensionRegistry._check` has three rules — namespace ownership, tool-id ownership,
        // namespace agreement — none of which is this one. The consequences are asserted here so
        // that the state of the tree is a checked fact and not a comment, and the day a fourth
        // rule appears these three assertions stop passing and say so.
        for (final prefix in reservedIdPrefixes) {
          expect(
            MethodNamespace.tryParse(prefix),
            isNotNull,
            reason: 'the namespace grammar admits `$prefix`, which is the gap',
          );
        }
        final (registry, failures) = ExtensionRegistry.build(<ExtensionUnit>[
          _unit('mem', const <String>[]),
        ]);
        expect(
          registry,
          isNotNull,
          reason: 'so nothing refuses a namespace named after a record-id prefix today',
        );
        expect(failures, isEmpty);
        expect(registry!.owns(MethodNamespace('mem')), isTrue);
      },
    );
  });
}

// -------------------------------------------------------------------------------------------
// Fixtures
// -------------------------------------------------------------------------------------------

/// The two `tools/` packages `overview.md` §2.2's v1 set gives, with the tool ids it lists.
///
/// Copied from the document's own row rather than invented, so that "a `tools/` namespace
/// routes" is a statement about the dispatch rule and not about ids nobody would write. Both
/// namespaces are exercised by the first test in the file, and the acceptance criterion names
/// "two registered plugins" — these are the two.
const Map<String, List<String>> toolPackages = <String, List<String>>{
  'web': <String>['web.search', 'web.fetch'],
  'fs': <String>['fs.read', 'fs.write', 'fs.edit', 'fs.delete', 'fs.list'],
};

// -------------------------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------------------------

/// The seeded `core` owner — `overview.md` §5's first row, "AlteriOneCore built-in methods".
///
/// A seeded unit rather than a registered one, and the tool ids it declares are the engine's
/// own surface: `core.run` and `core.initialize` both dispatch under `core`, and `core.run` is
/// the slashed spelling while `core.initialize` is the dotted one the handshake sends.
ExtensionUnit _engineUnit(MethodHandler handler) => ExtensionUnit(
  namespace: MethodNamespace.core,
  handler: handler,
  toolIds: const <String>['core.run', 'core.initialize'],
);

/// The seeded `$` owner — `overview.md` §5's second row, "Protocol control: `$/cancelRequest`,
/// `$/progress`".
///
/// No tool ids: the control plane is addressed by method, not by a tool id, and a tool id in
/// the `$/` namespace would be a fourth thing the reserved-prefix table does not describe.
ExtensionUnit _controlUnit(MethodHandler handler) =>
    ExtensionUnit(namespace: MethodNamespace.control, handler: handler);

/// A unit owning [namespace] and implementing [toolIds], answering through [handler].
ExtensionUnit _unit(
  String namespace,
  List<String> toolIds, {
  MethodHandler? handler,
}) => ExtensionUnit(
  namespace: MethodNamespace(namespace),
  handler: handler ?? _FakeHandler(),
  toolIds: toolIds,
);

/// The registry [units] bind into, or a failure naming the refusals that stopped it.
///
/// Written as a helper because "the registry built" and "the registry refused" are the two ways
/// a `registry!` silently becomes the null this file is asserting is never returned — and a
/// `!` in a test is a null-check error with no context at all.
ExtensionRegistry _bound(
  List<ExtensionUnit> units, {
  List<ExtensionUnit> seeded = const <ExtensionUnit>[],
}) {
  final (registry, failures) = ExtensionRegistry.build(units, seeded: seeded);
  if (registry == null) {
    fail(
      'these units are supposed to bind and they did not:\n'
      '${failures.map((failure) => failure.toString()).join('\n')}',
    );
  }
  return registry;
}

/// A one-way frame for [namespace]'s [method], with the default [params].
///
/// `module` is the namespace the frame belongs to, which is what the envelope's own
/// documentation says it is, and `meta` is the shipped one so the test never has to invent a
/// version that a reader would then believe was agreed.
NotificationEnvelope _notification(
  String namespace,
  String method, {
  JsonMap params = JsonMap.empty,
}) => NotificationEnvelope(
  module: namespace,
  meta: _meta,
  method: method,
  params: params,
);

/// The `meta` block every frame in this file carries.
///
/// A plain `ProtoMajor(1)` over a `1.0.0`, not a negotiated invariant: `toEnvelope` takes `meta`
/// as an argument precisely because `meta.proto` is the major a session *negotiated* and an
/// event published before any session existed cannot fill it in.
final EnvelopeMeta _meta = EnvelopeMeta(
  proto: ProtoMajor(1),
  moduleVersion: ProtoVersion(major: 1, minor: 0, patch: 0),
);

/// A root event, or a child one when [parentSpanId] is given.
///
/// Every argument has a default so that a test can vary exactly one field. The ids are drawn
/// from the reserved prefixes of `concepts.md` §2.1 with the eight hex digits the record-id
/// grammar allows, the timestamp is fixed rather than read from a clock — `observability.md`
/// §4 forbids production code from calling `DateTime.now`, and a test that read one would make
/// its own expected value depend on when it ran — and the payload is `RedactedPayload.empty`
/// because `engine.md` §4's "at least" is a floor and `task_started` is the event that sits on
/// it.
///
/// Two constructors rather than a nullable [parentSpanId] parameter, for the reason
/// `AlteriOneEvent` gives for having two: a reader of a call site has to be able to tell "this
/// event has no parent" from "this event has a parent and the caller forgot".
AlteriOneEvent _event({
  String id = 'evt_00000001',
  EventType type = EventType.taskStarted,
  DateTime? timestamp,
  String? parentSpanId,
  RedactedPayload? payload,
  Provenance provenance = Provenance.userStated,
}) {
  final stamp = timestamp ?? DateTime.utc(2026, 1, 2, 3, 4, 5, 678, 900);
  final body = payload ?? RedactedPayload.empty;
  if (parentSpanId != null) {
    return AlteriOneEvent.child(
      eventId: id,
      traceId: _traceId,
      spanId: 'span_00000002',
      parentSpanId: parentSpanId,
      timestamp: stamp,
      eventType: type,
      profile: _profileName,
      projectId: _projectId,
      provenance: provenance,
      schemaVersion: eventSchemaVersion,
      payload: body,
    );
  }
  return AlteriOneEvent.root(
    eventId: id,
    traceId: _traceId,
    spanId: 'span_00000001',
    timestamp: stamp,
    eventType: type,
    profile: _profileName,
    projectId: _projectId,
    provenance: provenance,
    schemaVersion: eventSchemaVersion,
    payload: body,
  );
}

/// The run [_event] belongs to. `concepts.md` §2.1's record-id grammar, `overview.md` §6's
/// mandatory `traceId`, and the span ids the parent/child tests read back.
const String _traceId = 'trace_9f2c41ab';

/// The profile name every event in this file carries — a name, not a `Profile`, because
/// `event.dart` says an event outlives any one profile document.
const String _profileName = 'companion';

/// The project id, in `observability.md` §2.1's hash form rather than a path, so the record is
/// portable between two machines.
const String _projectId = 'proj_0a1b2c3d';

/// A [MethodHandler] that answers every call and records what it was asked.
///
/// The narrowest double the interface allows: `MethodHandler` has one member, and
/// `plugins.md` §1's `AlteriOnePlugin` is *wider* — it adds a manifest, a lifecycle and an
/// event stream, none of which exists yet. A plugin satisfies this by implementing a method it
/// already has, and `0.29` widens the interface without touching the registry or the
/// dispatcher, so a double of the narrow contract is also a double of the wide one.
///
/// Local to this file rather than in `lib/src/fakes/`, and the reason is that the shipped
/// doubles are for *other* packages' tests: `memory.md` §4 and `cli.md` §5 script a
/// `FakeProvider`, and a test double that only this file can reach is not what that arrangement
/// is for.
final class _FakeHandler implements MethodHandler {
  /// Answers everything, or throws for each method named in [failOn].
  ///
  /// The message carried by the thrown [StateError] is a parameter because the redaction
  /// assertion needs a message containing something that must not escape, and a double with a
  /// fixed message would make that test a statement about the double.
  _FakeHandler({this.error = 'handler failed'});

  /// The message carried by the thrown [StateError].
  final String error;

  /// The methods this handler refuses to answer.
  ///
  /// A mutable field rather than a constructor argument, so one handler can answer a call and
  /// then throw on the next. That is what the `-32603` redaction assertion needs: its positive
  /// control is the *same* handler and the *same* secret, so a double that could only be
  /// configured to always fail would need two instances and would no longer be a control.
  final Set<String> failOn = <String>{};

  /// Every method this handler was reached through, in order.
  final List<String> seen = <String>[];

  /// The operation of every call, in the same order as [seen].
  ///
  /// A separate list from [seen] because the separator tests are about the *operation* — what
  /// a handler sees for `core/run` against what it sees for `core.initialize` — and a combined
  /// list would make that a string comparison.
  final List<String> operations = <String>[];

  @override
  Future<AlteriOneResult> handle(MethodCall call) async {
    seen.add(call.method);
    operations.add(call.operation);
    if (failOn.contains(call.method)) {
      throw StateError(error);
    }
    return AlteriOneResult(
      JsonMap({
        'method': call.method,
        'namespace': call.namespace.value,
        'operation': call.operation,
        'params': call.params,
      }),
    );
  }

  @override
  String toString() {
    final failing = failOn.isEmpty ? '' : ', fails ${failOn.join(' ')}';
    return '_FakeHandler(${seen.length} call(s)$failing)';
  }
}

/// The repository root, found by walking up from the working directory.
///
/// The acceptance command is `melos exec --scope=alteri_one_core -- dart test …` and melos runs
/// it *in the package*, so a test that opened `docs/concepts.md` relative to the working
/// directory would work when run from the root by hand and fail in the one place it has to
/// work. A test that only passes in the way its author runs it is a test that will be skipped.
Directory _repositoryRoot() {
  const relative = 'docs/concepts.md';
  var directory = Directory.current;
  while (true) {
    if (File('${directory.path}/$relative').existsSync() &&
        Directory('${directory.path}/packages').existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        '$relative and packages/ not found above ${Directory.current.path}; this test needs '
        'the repository, and it looks for the file rather than assuming where it was run from',
      );
    }
    directory = parent;
  }
}

/// The first column of `docs/architecture/overview.md` §5's dispatch table, in order.
///
/// The table is bounded by its own header and by the first line after it that is not a row, and
/// only the first column is read: the second is prose that happens to contain backticks.
List<String> _documentedDispatchPrefixes(Directory root) {
  final file = File('${root.path}/docs/architecture/overview.md');
  final prefixes = <String>[];
  var inSection = false;
  var inTable = false;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('## 5.')) {
      inSection = true;
      continue;
    }
    if (inSection && line.startsWith('## ')) inSection = false;
    if (!inSection) continue;
    if (RegExp(r'^\|\s*Prefix\s*\|\s*Routed to\s*\|').hasMatch(line)) {
      inTable = true;
      continue;
    }
    if (!inTable) continue;
    if (!line.trimLeft().startsWith('|')) break;
    if (line.trimLeft().startsWith('|---')) continue;
    final cells = line.split('|');
    // Two columns, so `| a | b |` splits into four elements: the two empty ends are part of the
    // split. A row with any other cell count is a different table, and the header match above
    // has already established that this one has two.
    if (cells.length != 4) break;
    // The backticks are markdown, not part of the prefix. Stripping them is what makes the
    // comparison a comparison of spellings: `` `core/*` `` and `core/*` are the same prefix, and
    // a parser that kept the ticks would fail on a formatting change rather than on a change of
    // meaning.
    prefixes.add(cells[1].trim().replaceAll('`', ''));
  }
  if (prefixes.isEmpty) {
    throw StateError(
      'no dispatch prefixes parsed from ${file.path} §5; the table format changed, and a parser '
      'that reads nothing would compare an empty list against nothing and pass',
    );
  }
  return prefixes;
}

/// The prefixes `docs/concepts.md` §2.1 reserves, split by what they are reserved for.
///
/// `methods` are the two method prefixes as the table writes them, with the trailing slash
/// intact, so a comparison against `reserved` is a comparison of the *document's* spelling.
/// `ids` are the six record-id prefixes with the trailing underscore stripped, because
/// `reservedIdPrefixes` holds the stem and the underscore belongs to the record-id grammar.
///
/// The first cell only. §2.1's table puts method names in backticks in the second column
/// (`` `$/cancelRequest`, `$/progress` ``) and a parser that swept the row would read those as
/// reservations.
({List<String> methods, List<String> ids}) _documentedReservations(
  Directory root,
) {
  final file = File('${root.path}/docs/concepts.md');
  final methods = <String>[];
  final ids = <String>[];
  var inSection = false;
  var inTable = false;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('### 2.1')) {
      inSection = true;
      continue;
    }
    if (inSection && line.startsWith('#')) inSection = false;
    if (!inSection) continue;
    if (RegExp(r'^\|\s*Prefix\s*\|\s*Reserved for\s*\|').hasMatch(line)) {
      inTable = true;
      continue;
    }
    if (!inTable) continue;
    if (!line.trimLeft().startsWith('|')) break;
    if (line.trimLeft().startsWith('|---')) continue;
    final cells = line.split('|');
    if (cells.length != 5) break;
    final tokens = RegExp(r'`([^`]+)`')
        .allMatches(cells[1])
        .map((match) => match.group(1)!)
        .toList();
    if (tokens.isEmpty) continue;
    if (cells[1].contains('(method)')) {
      methods.addAll(tokens);
    } else {
      ids.addAll(
        tokens.map(
          (token) => token.endsWith('_')
              ? token.substring(0, token.length - 1)
              : token,
        ),
      );
    }
  }
  if (methods.isEmpty || ids.isEmpty) {
    throw StateError(
      'the reservations parsed from ${file.path} §2.1 are '
      '${methods.length} method(s) and ${ids.length} id prefix(es); the table format changed',
    );
  }
  return (methods: methods, ids: ids);
}

/// The namespaces `lib/src/core/namespace.dart` spells, as (declaration name, wire value).
///
/// Parsed from the source rather than reflected on, because the property under test is about
/// the *text* a new namespace would have to be added to: a third `static const
/// MethodNamespace` in that file is the core edit `overview.md` §5 says is not needed, and a
/// reflection-based check would not see a namespace declared in a `switch` or a map literal.
///
/// The pattern requires the whole declaration — the `static const`, the type, a name and a
/// `MethodNamespace._(` — so the class's own private constructor and the factory's `parsed`
/// return are not mistaken for declared namespaces. A double-quoted raw string, because the
/// pattern contains a `'` (in both `'core'` and `r'$'`) and a raw string cannot contain its own
/// delimiter.
List<(String, String)> _declaredNamespaces(Directory root) {
  final file = File(
    '${root.path}/packages/alteri_one_core/lib/src/core/namespace.dart',
  );
  if (!file.existsSync()) {
    throw StateError(
      '${file.path} moved; the "without core edits" check reads it by path',
    );
  }
  final pattern = RegExp(
    r"static const MethodNamespace ([a-zA-Z]+) = MethodNamespace\._\((?:r)?'([^']*)'\);",
  );
  final declared = pattern
      .allMatches(file.readAsStringSync())
      .map((match) => (match.group(1)!, match.group(2)!))
      .toList();
  if (declared.isEmpty) {
    throw StateError(
      'no `static const MethodNamespace` declaration parsed from ${file.path}; a parser that '
      'reads nothing would compare an empty set against reserved and pass',
    );
  }
  return declared;
}
