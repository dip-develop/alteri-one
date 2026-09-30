/// The namespace of a method, a tool or an event topic: the leading segment, and nothing else.
///
/// `docs/architecture/overview.md` §5 is the table this file implements — `core/*` to the
/// built-in methods, `$/` to protocol control, `<namespace>.*` to the plugin registered under
/// `<namespace>` — and `docs/concepts.md` §2 states the rule that makes it work: "**the tool
/// namespace prefix is the dispatch key**. `web.*` is dispatched by the plugin registered under
/// the `web` namespace. Adding a tool with a new namespace requires no core change."
///
/// ## Why one rule covers two vocabularies
///
/// The documents use **two different separators** and do not reconcile them:
///
/// | Spelling | Where | Example |
/// |---|---|---|
/// | `/` | `protocol.md` §1's namespaced method, `concepts.md` §2's event topic | `core/run`, `core/step_completed` |
/// | `.` | `overview.md` §5's dispatch row, `concepts.md` §2's tool id | `<namespace>.*`, `web.search` |
/// | `.` | `protocol.md` §4's handshake, and the shipped `initializeMethod` | `core.initialize` |
///
/// Three spellings, one question. Rather than pick a separator and reject the other two, the
/// namespace is the **leading `[a-z][a-z0-9_]*` run** and the separator is whatever follows it.
/// `core/run`, `core.initialize`, `$/progress` and `web.search` all answer `core`, `core`, `$`
/// and `web` respectively, and no caller has to know which spelling produced it.
///
/// That is not a compromise to make the tests pass; it is the only reading under which every
/// documented spelling dispatches, and the alternative — one separator — would make
/// `core.initialize` unroutable, which is the one method the shipped handshake already uses.
/// The divergence is recorded in `TODO.md` rather than resolved here, because picking a
/// separator is a change to a documented contract and not this file's decision.
///
/// ## Why the value is parsed rather than compared
///
/// A `String` namespace invites `method.split('/').first` at each of the three call sites, and
/// the three are exactly where a spelling disagreement would show up as a method that routes
/// nowhere. [MethodNamespace.tryParse] is the one place the grammar lives, and the reserved
/// prefixes are members of the type rather than string comparisons a caller can forget.
library;

/// A dispatch namespace: the leading segment of a method, tool id or event topic.
///
/// A `final class` with a validating constructor rather than an `enum`, and the reason is that
/// the set is not closed: any package may register a new namespace, and `overview.md` §5's
/// promise is that doing so needs no core change. An enum of today's namespaces would have to be
/// edited to add tomorrow's, which is precisely the core change the rule forbids.
final class MethodNamespace implements Comparable<MethodNamespace> {
  /// Creates a namespace, throwing [ArgumentError] for anything [tryParse] would refuse.
  ///
  /// The throwing constructor is for a **literal** a programmer wrote, where a bad value is a
  /// typo in this repository; a value that came from configuration goes through [tryParse] and
  /// becomes a diagnostic.
  factory MethodNamespace(String value) {
    final parsed = tryParse(value);
    if (parsed == null) {
      throw ArgumentError.value(
        value,
        'value',
        'is not a namespace. A namespace is the leading segment of a method, a tool id or an '
            'event topic, and the grammar is ${namespaceGrammar.pattern}',
      );
    }
    return parsed;
  }

  const MethodNamespace._(this.value);

  /// The parsed form, or null when [value] is not one.
  static MethodNamespace? tryParse(String value) {
    if (value.isEmpty) return null;
    final match = namespaceGrammar.matchAsPrefix(value);
    if (match == null) return null;
    return MethodNamespace._(match.group(0)!);
  }

  /// The leading segment of [method], or null when [method] does not begin with one.
  ///
  /// A **prefix** match and not a whole-string match, and the difference is the whole design: a
  /// method is `namespace` + a separator + an operation, and the operation is not the
  /// dispatcher's business. `core/` matches `core/run` and `core/stop`; it also matches a bare
  /// `core`, which is a method with no operation and is refused later by the dispatcher rather
  /// than here, because "what a nameless method means" is not a question about namespaces.
  static MethodNamespace? of(String method) => tryParse(method);

  /// The leading segment of a dotted tool id: `web.search` dispatches under `web`.
  ///
  /// A separate name from [of] because the two answer different documents and a reader should be
  /// able to tell which one a call site means. The implementation is shared, and the split is
  /// documentation rather than behaviour — `concepts.md` §2 calls the dotted prefix "the dispatch
  /// key" and that is the phrase this member carries.
  static MethodNamespace? dispatchKeyOf(String toolId) => tryParse(toolId);

  /// The namespace the engine's own methods live in.
  static const MethodNamespace core = MethodNamespace._('core');

  /// The namespace the protocol control plane lives in.
  ///
  /// `$` and not `dollar`: `$/cancelRequest` and `$/progress` are the two reserved control
  /// methods and the `$` is part of their spelling on the wire, so the namespace has to *be* that
  /// character. It is the one namespace that is not a word, which is why [reserved] is a list and
  /// not a range.
  static const MethodNamespace control = MethodNamespace._(r'$');

  /// The namespace as it appears on the wire.
  final String value;

  /// Whether this is one of [reserved] — the core's or the control plane's.
  bool get isReserved => reserved.contains(this);

  /// The full method this namespace dispatches, with [operation] appended.
  ///
  /// The inverse of [of] for the slashed spelling, and the reason the namespace is a value with
  /// a `value` rather than an opaque token: a unit's registration names a namespace and a
  /// handler, and a test needs to build the method that reaches them.
  String method(String operation) => '$value/$operation';

  @override
  int compareTo(MethodNamespace other) => value.compareTo(other.value);

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is MethodNamespace && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// The namespaces no extension may claim.
///
/// [docs/concepts.md] §2.1 reserves `core/` for the engine's own methods and `$/` for the
/// protocol control plane, and says "a tool, an injection or a plugin MUST NOT declare a tool
/// or an event topic in a reserved namespace".
///
/// **`core` and `$` are reserved because they are already *owned*, and the registry models it
/// that way rather than checking a list.** `overview.md` §5 says a namespace's owner "is exactly
/// one package, and it is either a `tools/` package or a `plugins/` package — never two, never
/// an app and never the core". So the registry is seeded with the core and the control plane as
/// its first two owners, and an extension claiming either is a **second owner for one
/// namespace** — `extension.duplicate_id`, the code `error-codes.md` §3 already defines for
/// exactly this. A separate "is this reserved?" check would be a second rule for a situation
/// the ownership rule already covers, and two rules for one situation is one more than can be
/// enforced consistently.
const reserved = <MethodNamespace>[
  MethodNamespace.core,
  MethodNamespace.control,
];

/// The id prefixes `IdGenerator` owns, from [docs/concepts.md] §2.1.
///
/// **Documentary, and nothing enforces it.** An earlier version of this comment claimed "a
/// namespace must not be one of them" and gave a collision argument — that a unit named `trace_`
/// would have ids indistinguishable from a record id in a log. The argument is wrong and the
/// claim with it: a namespace `trace_` produces methods like `trace_/search` and tool ids like
/// `trace_.search`, while a record id is `trace_01f4a9c2` — the underscore *binds a hex block*
/// (`concepts.md` §2's grammar is `_(hex)+`), so a namespace can never be a prefix of a record
/// id. The same comment also said "`trace_` and `mem_` are not valid namespaces anyway", which is
/// false in the same breath: `_` is legal after a letter, so they are.
///
/// So the list is here because a caller validating its own identifiers needs the reserved set
/// from the same place as the grammar that reserves it, and the registry does **not** refuse a
/// namespace for being in it — because there is no collision to refuse. The contract test records
/// the absence as a checked fact rather than leaving it as prose: a unit owning `mem` binds, and
/// if a rule is ever added that test is where it says so.
const reservedIdPrefixes = <String>[
  'trace',
  'req',
  'span',
  'evt',
  'mem',
  'art',
];

/// The grammar of a namespace: the leading run of a lowercase identifier, **or `$`**.
///
/// Public because a caller validating a *tool id* or an *event topic* needs the same knowledge,
/// and importing a private pattern for it is worse than publishing it. It is a **prefix** pattern
/// — a namespace is the leading run of a longer identifier, and [MethodNamespace.of] relies on
/// that — so it must not be used with [RegExp.hasMatch] against a whole id.
///
/// **`$` is in the grammar, and omitting it made §5's second row unreachable.** The alternative
/// branches were `^[a-z][a-z0-9_]*` and "`$/` is the constant [MethodNamespace.control], reach it
/// as a constant". Both are wrong for the same reason: [MethodNamespace.of] takes a *method*
/// string, and the control plane's own two methods are `$/cancelRequest` and `$/progress`. With
/// the alternative the type could not represent its own wire spelling — `MethodNamespace(r'$')`
/// threw, `MethodCall('$/cancelRequest')` threw, and `registry.owns(MethodNamespace.control)` was
/// `true` while no dispatch could ever reach the owner. `overview.md` §5's middle row was
/// therefore dead code wearing a passing test: the constant existed, the seed existed, and
/// nothing could arrive.
///
/// `$` is admitted as the whole namespace rather than as a prefix of a word, because `$/` is a
/// *reserved method prefix* (`concepts.md` §2.1) and not a namespace anyone names freely: a unit
/// claiming `core` is refused as a duplicate owner, and one claiming `$` is refused the same way.
final RegExp namespaceGrammar = RegExp(r'^(\$|[a-z][a-z0-9_]*)');

/// The tool-id grammar from [docs/concepts.md] §2: `namespace.operation`.
///
/// A whole-string pattern, unlike [namespaceGrammar], because a tool id is complete as written.
/// `tools.md` §1.2 filters on a tool id long before anything is registered, so this is the
/// pattern a caller validating one wants.
final RegExp toolIdGrammar = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');

/// The event-topic grammar from [docs/concepts.md] §2: `core/step_completed`.
///
/// Slashed, and **`+` rather than `*` on the trailing group**, because that is what the document
/// writes: `^[a-z][a-z0-9_]*(\/[a-z][a-z0-9_]*)+$`. An earlier version of this pattern narrowed
/// the trailing group to exactly one segment and said in a comment that "`concepts.md` says so"
/// — which it does not, and the comment made the narrowing look specified. The consequence is
/// invisible from a topic this package produces (every one it builds has two segments) and
/// real for anything that validates a topic it did not write: a three-segment topic
/// `a/b/c` is legal by §2's grammar and would have been refused here.
///
/// A topic is a *string* with a namespace as its leading segment, and the number of segments
/// after it is not a dispatch concern — [`MethodNamespace.of`] takes the leading run and the
/// dispatcher routes on that. So this pattern is a validity check and nothing more, and it is
/// written to agree with the table rather than to be convenient.
final RegExp eventTopicGrammar = RegExp(
  r'^[a-z][a-z0-9_]*(/[a-z][a-z0-9_]*)+$',
);
