/// `core.initialize`: the one request that decides whether a session exists.
///
/// [architecture/protocol.md] §4 is the specification and §4.1 to §4.4 are four decisions
/// layered on top of the two JSON examples there — the `api` block a successful result
/// carries, the shape an accepted or refused handshake may take, what the negotiation
/// actually computes, and the grammar of the range it computes against. This file implements
/// all four, and every one of them is somewhere a peer can get it wrong:
///
/// - **A refusal is an `error` response, not a result carrying `accepted: false`.** §1 makes
///   `result` and `error` mutually exclusive, so one frame cannot hold both. A peer reading a
///   refused handshake looks for the error, and [HandshakeRefused.toResponse] is what puts it
///   there. The `accepted` member therefore appears in a result only as `true`.
/// - **The negotiated version is the host's, and two ranges must admit it** — the peer's
///   `protoVersionRange` and the host's own `api.protocol`. Not "the highest version both
///   could support": this package holds exactly one version per side, and choosing between
///   two would be a second one to get wrong for a case that has not happened yet.
/// - **A limit is the minimum of three numbers** — the peer's proposal, the host's own, and
///   the hard cap — and that minimum is arithmetic in [SessionLimits.minimum] rather than a
///   request to both sides' good behaviour.
/// - **Only `capability_mismatch` ever degrades**, and that is a property of the *cause*, not
///   of configuration: a host that cannot speak the peer's version has nothing to warn and
///   continue with.
/// - **`degradePolicy` is chosen, never inferred.** A missing or unrecognised value refuses
///   the handshake rather than defaulting, because defaulting to `refuse` is the safe answer
///   and the wrong one — it silently accepts a peer that forgot to choose, and the operator
///   never learns the policy was never set.
///
/// [negotiateHandshake] is a pure function of its three arguments: no clock, no id
/// generator, no `dart:io`, no ambient configuration. A handshake that needed a clock would
/// be a handshake that could not be tested without one, and determinism is an invariant in
/// this repository.
///
/// Its output is also the only library code in this package that constructs a
/// [SessionVersionInvariant], through [HandshakeAccepted]. Before an accepted handshake
/// `meta.proto` is the sender's major and nothing has been agreed, so "not yet negotiated"
/// has to be the *absence* of the value — which is why there is no session holding a nullable
/// version, and why [InitializeResult] deliberately has no `invariant` getter of its own.
///
/// ## Why the range lives here and not in `version.dart`
///
/// [version.dart] states the omission and its reason: this package has **no dependencies**,
/// `pub_semver` is not one of them, and a wire-compatibility promise about this protocol
/// should be reviewable in this repository rather than delegated to a general range engine.
/// Reading two integers and comparing them is a different problem from deciding whether a
/// range is *satisfied*, so the two live in two files. The grammar is one form — `>=`, `>`,
/// `<=`, `<`, `=` or a bare version, whitespace separated, every comparator holding — because
/// every document in the repository writes one form, and a parser that accepts a second has
/// two answers to "is 1.5.0 inside this range".
///
/// [ADR-0002]: ../../../../docs/decisions/0002-protocol-envelope.md
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [concepts.md]: ../../../../docs/concepts.md
/// [reference/config-schema.md]: ../../../../docs/reference/config-schema.md
library;

import 'dart:math' show min;

import 'envelope.dart';
import 'error.dart';
import 'framing.dart';
import 'json.dart';
import 'version.dart';

/// What a host does when the peer asks for a capability it does not publish.
///
/// The two values §4.3 names and no others, and a host **chooses** one: [fromWireName]
/// returning null is the third answer, and it is a refused handshake rather than a default.
///
/// The alternative was inferring a policy from the absence of a member — treat a missing
/// `degradePolicy` as `refuse` and every unconfigured host fails closed, which reads like the
/// safe answer and is not one. It is not one because the *fail-closed* decision would then be
/// made by this package rather than by the operator who configures the host, it would be
/// invisible — the wire result would read `refuse` whether the host meant it or forgot to
/// say — and the two cases an operator needs to tell apart become indistinguishable. An
/// unrecognised value is refused for the same reason, plus a hint that the value is not one
/// this version defines.
enum DegradePolicy {
  /// Any disagreement fails the handshake. The default reading of §4.3's "fail-closed".
  refuse('refuse'),

  /// A degradable cause becomes a recorded warning and the session continues.
  ///
  /// Only ever for a cause the host **named in advance** — which today is exactly
  /// [HandshakeCause.capabilityMismatch] — because §5 permits `warn+degrade` "only under a
  /// policy defined in advance", and sandbox, secrets, egress and Tier 2 stay fail-closed
  /// whatever this says.
  warnAndDegrade('warn+degrade');

  const DegradePolicy(this.wireName);

  /// The value of the `degradePolicy` member.
  final String wireName;

  /// The policy named [name], or null when the member carries something else.
  ///
  /// Takes [Object?] rather than `String?` so a reader can hand over the raw member and let a
  /// non-string be a plain miss, for the reason [EnvelopeType.fromWireName] gives: this is a
  /// member whose value decides whether the rest of the result is worth reading.
  ///
  /// Null rather than a throw, and the caller turns null into a refusal rather than a
  /// default. See this enum's documentation.
  static DegradePolicy? fromWireName(Object? name) {
    if (name is! String) return null;
    for (final policy in DegradePolicy.values) {
      if (policy.wireName == name) return policy;
    }
    return null;
  }
}

/// A version constraint: a whitespace-separated conjunction of comparators, **all** of which
/// must hold for a version to be inside the range.
///
/// The grammar is §4.4's and is deliberately the smallest thing that expresses the
/// constraints this protocol actually uses:
///
/// ```text
/// range     := comparator ( WS+ comparator )*
/// comparator := ( ">=" | ">" | "<=" | "<" | "=" )? version
/// ```
///
/// A bare `X.Y.Z` is `=X.Y.Z`, which is why the grammar has a bare version at all: §4 states
/// that `api.extension: "1.0.0"` is a range admitting exactly `1.0.0`. The *second* reason §4
/// gives is `api.ports.mcp: "2026-07-28"`, a date-shaped version rather than a semver, so a
/// bare version is a version **token** and the token may be a date. A date is exact or
/// nothing: there is no precedence to order it by, so it is refused in an ordering position and
/// [allows] — which takes a [ProtoVersion] — admits nothing for one, because no
/// [ProtoVersion] spells a date. That is the honest consequence of [ProtoVersion] being a
/// semver, and the type that can hold a date arrives with the MCP dialect adapter.
///
/// **No `^`, no `~`, no `||`, no `*`, no hyphen ranges.** The rejected alternative is npm's
/// and Cargo's grammar, and the reason is not that those are wrong — they are careful,
/// specified grammars — but that every document in this repository writes the conjunction
/// form. A parser that accepts a second form has two answers to "is 1.5.0 inside this
/// range", and two answers is one more than a protocol can carry without the peers disagreeing
/// about what was agreed. A range outside the grammar is therefore refused with the offending
/// token named, never partially understood.
///
/// Comparison is semver *precedence*, which [ProtoVersion.compareTo] implements: build
/// metadata is ignored, and a pre-release sorts below the release it precedes. So
/// `1.0.0-alpha.1` does **not** satisfy `>=1.0.0 <2.0.0`. That is the correct answer rather
/// than an accident — a peer offering a pre-release to a range that starts at the release has
/// said it is not that release, and the handshake is the cheapest place to find out. Special-
/// casing it to "probably meant `>=`" is the leniency `version.dart` refuses to extend to a
/// version, and a lenient range engine here is how `1.0` and `1.0.0` end up meaning different
/// things on either side of a socket.
final class ProtoVersionRange {
  /// Parses [text], throwing a [FormatException] naming the offending token.
  ///
  /// A [FormatException] rather than a [ProtocolViolation]: this is a constructor, and its
  /// caller is code reading configuration or building a request, not a decoder answering a
  /// peer. [parseOrNull] is the form a reader of the wire uses, and
  /// [InitializeParams.fromParams] and [HostApiVersions.fromJson] convert this one into a
  /// `-32602` themselves.
  factory ProtoVersionRange.parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw FormatException(
        'a version range is a conjunction of comparators and needs at least one, so an empty '
        'range admits nothing rather than everything',
        text,
      );
    }
    final comparators = <_Comparator>[
      for (final token in trimmed.split(_whitespace)) _Comparator.parse(token),
    ];
    return ProtoVersionRange._(text, comparators);
  }

  ProtoVersionRange._(this._wire, this._comparators);

  /// Parses [text], or returns null.
  ///
  /// The null-returning form, for a reader that has to report a protocol error rather than a
  /// programming error: a peer sent `"protoVersionRange": "^1.0.0"` and that is a `-32602` on
  /// the frame, not a crash in the host.
  static ProtoVersionRange? parseOrNull(String text) {
    try {
      return ProtoVersionRange.parse(text);
    } on FormatException {
      return null;
    }
  }

  /// The range every v1 document in this repository writes.
  ///
  /// §4's own example, [reference/config-schema.md] §1.2's `api.protocol` and every
  /// product-manifest fixture. Named rather than inlined so that "which range is v1" has one
  /// answer; an inline `>=1.0.0 <2.0.0` at a second call site is a second place to change it.
  ///
  /// A `static final` and not a `static const`, because a range is parsed and a `const` cannot
  /// hold the result of a computation — the same reason [ProtoVersion.current] is one.
  static final ProtoVersionRange v1 = ProtoVersionRange.parse('>=1.0.0 <2.0.0');

  final String _wire;
  final List<_Comparator> _comparators;

  /// The text as given.
  ///
  /// Not a canonical re-rendering, and that is the point: the value a peer wrote is what goes
  /// back out, so a round trip through this class returns the peer's spelling and not a
  /// normalised one. Two ranges that accept the same versions can still carry different `wire`
  /// text, which is why [operator ==] is not defined on it — see there.
  String get wire => _wire;

  /// Whether [version] is inside the range, i.e. whether every comparator holds.
  ///
  /// The whole behaviour of this class. The comparator list stays private because a caller that
  /// inspects the comparators is a caller that has to re-implement [ProtoVersion.compareTo] to
  /// make sense of them, and a re-implemented comparison is how a session starts disagreeing
  /// about precedence.
  bool allows(ProtoVersion version) {
    for (final comparator in _comparators) {
      if (!comparator.holds(version)) return false;
    }
    return true;
  }

  /// Equality over the comparators **in the order written**, not over [wire].
  ///
  /// So `1.0.0` and `=1.0.0` are equal — one range, two spellings of it — while
  /// `>=1.0.0 <2.0.0` and `<2.0.0 >=1.0.0` are not, even though a conjunction is
  /// order-independent and both accept the same versions. The asymmetry is deliberate and the
  /// two members answer different questions: [wire] is *what the peer wrote*, and preserving it
  /// is what makes a handshake echo the peer's own constraint back; `==` is *what this value
  /// is*, and it must not inherit the cosmetic freedom [wire] has to keep.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ProtoVersionRange) return false;
    if (other._comparators.length != _comparators.length) return false;
    for (var i = 0; i < _comparators.length; i++) {
      if (other._comparators[i] != _comparators[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_comparators);

  @override
  String toString() => wire;
}

/// 64: the hard cap on how deeply a payload may nest, from §2's table.
///
/// Enforced when the codec lands, and negotiated here; §4.3 is explicit that the two arrive in
/// the same task, because "a negotiated number with no enforcement behind it is a claim".
const int hardMaxJsonDepth = 64;

/// 32: the hard cap on concurrent in-flight requests per peer, from §2's table.
///
/// Enforced when the dispatcher lands — the dispatcher is what has a queue to bound, and this
/// package has no queue. Negotiated here for the same reason as [hardMaxJsonDepth].
const int hardMaxConcurrentRequests = 32;

/// The four limits a session negotiates, as four flat numbers.
///
/// Flat, and not a nested [FrameLimits], because these four are **one** negotiated object on
/// the wire: `limits` in §4's example is `{ maxFrameBytes, maxJsonDepth, maxConcurrentRequests
/// }` with no nesting, and a nesting level would have to be spelled in `params` and in every
/// peer's decoder. [frames] is the accessor for a caller that wants the two framing numbers as
/// the type the codec takes, and it costs nothing to provide rather than having a caller
/// rebuild one.
///
/// §2's table has **five** rows and only four are here. The fifth — 256 queued pending responses
/// — is not a negotiated number: [framing.dart] documents `defaultMaxQueuedFrames` as local
/// per-transport policy, because the depth bound is a property of one transport's queue and not
/// a fact two peers can agree about. Negotiation carries what §4's example carries.
///
/// Not a fifth row either, and worth being explicit about: a byte budget for the outbound queue
/// is *also* local policy in `framing.dart`, and the reason is the same — a queue is a
/// transport's, and there is nothing for the other end of the socket to have an opinion about.
final class SessionLimits {
  /// Creates limits, defaulting to the hard caps.
  ///
  /// The asserts are debug-mode only, and [capped] is the check that holds in every build —
  /// the identical arrangement [FrameLimits] uses, and for the identical reason: a value above
  /// a hard cap is *clamped* rather than honoured, because a limit that configuration can raise
  /// is not a limit. §4.3 makes that a negotiation rule as well as a framing one, so
  /// [negotiateHandshake] resolves `minimum(...).capped` once and the result travels.
  const SessionLimits({
    this.maxFrameBytes = hardMaxFrameBytes,
    this.maxHeaderBytes = hardMaxHeaderBytes,
    this.maxJsonDepth = hardMaxJsonDepth,
    this.maxConcurrentRequests = hardMaxConcurrentRequests,
  }) : assert(maxFrameBytes > 0),
       assert(maxHeaderBytes > 0),
       assert(maxJsonDepth > 0),
       assert(maxConcurrentRequests > 0);

  /// Reads limits from [json], clamped to the hard caps.
  ///
  /// An **unknown** member is `-32602` and a member that is present but is not a positive
  /// `int` is `-32602`, both naming `$path.<member>`: a `limits` block carrying a member this
  /// version does not define would be dropped, and a silently dropped member is how two peers
  /// disagree about what was agreed — the same reasoning the codec applies to a frame, to a
  /// `meta`, and to a header block.
  ///
  /// An **absent** member is the hard cap, and that is the one asymmetry. A limit the peer did
  /// not mention is not a request to lower it: it is a member of an object the peer spelled
  /// partially, and reading silence as `0` or as "unbounded" would make the negotiation depend
  /// on a field's presence in a way no reader can predict. [toJson] then tells the peer all
  /// four, so the answer is never partial even when the request was.
  ///
  /// The result is [capped], so a peer proposing 16 MiB gets 8 MiB back out of here and the
  /// number never has to be clamped a second time. A `double` is not an `int` and is refused:
  /// `8388608.0` is a second spelling of one limit.
  factory SessionLimits.fromJson(
    JsonMap json, {
    String path = r'$.params.limits',
  }) {
    _rejectUnknownMembers(json, _limitMembers, path, 'limits');
    int read(String name) {
      if (!json.containsKey(name)) return _limitDefaults[name]!;
      final value = json[name];
      if (value is! int || value <= 0) {
        throw _invalidParams(
          '$path.$name',
          'is ${_quoted(value)}, expected a positive integer: a limit that is not a count '
              'cannot be enforced, and a limit of zero would refuse every frame',
        );
      }
      return value;
    }

    return SessionLimits(
      maxFrameBytes: read('maxFrameBytes'),
      maxHeaderBytes: read('maxHeaderBytes'),
      maxJsonDepth: read('maxJsonDepth'),
      maxConcurrentRequests: read('maxConcurrentRequests'),
    ).capped;
  }

  /// The limits §2's table states, which are also the hard caps.
  static const SessionLimits defaults = SessionLimits();

  /// The largest payload a frame may declare, in bytes.
  final int maxFrameBytes;

  /// The largest header block a frame may have, in bytes.
  final int maxHeaderBytes;

  /// How deeply a payload may nest.
  final int maxJsonDepth;

  /// How many requests may be in flight at once.
  final int maxConcurrentRequests;

  /// The two framing limits as the [FrameLimits] the codec and the transport take.
  FrameLimits get frames =>
      FrameLimits(maxFrameBytes: maxFrameBytes, maxHeaderBytes: maxHeaderBytes);

  /// These limits with each value held to its hard cap.
  ///
  /// Identity for every honest caller, since the defaults *are* the caps. A caller holding an
  /// uncapped [SessionLimits] — one built from configuration, or one read off the wire before
  /// [fromJson] clamped it — is holding a request, not a limit; reading it through here is what
  /// turns the request into one, in a build with the asserts compiled out as well as in one
  /// without.
  SessionLimits get capped => SessionLimits(
    maxFrameBytes: min(maxFrameBytes, hardMaxFrameBytes),
    maxHeaderBytes: min(maxHeaderBytes, hardMaxHeaderBytes),
    maxJsonDepth: min(maxJsonDepth, hardMaxJsonDepth),
    maxConcurrentRequests: min(
      maxConcurrentRequests,
      hardMaxConcurrentRequests,
    ),
  );

  /// The per-field minimum of [a] and [b].
  ///
  /// This is where §4.3's "may negotiate lower, never higher" stops being a sentence and
  /// becomes arithmetic: the negotiation takes the minimum of the peer's proposal, the host's
  /// own and the hard cap, and takes it *here*, once, rather than asking both sides to behave.
  /// A peer asking for 16 MiB is granted 8 MiB and told 8 MiB — the answer is the clamp, not a
  /// rejection, because a peer asking for too much is asking for a conversation rather than
  /// committing a breach.
  ///
  /// Not `capped`: this is the agreement between two peers, and the hard cap is a third input
  /// that the caller folds in. Keeping them apart means a caller cannot accidentally agree to
  /// 32 MiB with a peer that both of them happen to have configured that way.
  static SessionLimits minimum(SessionLimits a, SessionLimits b) =>
      SessionLimits(
        maxFrameBytes: min(a.maxFrameBytes, b.maxFrameBytes),
        maxHeaderBytes: min(a.maxHeaderBytes, b.maxHeaderBytes),
        maxJsonDepth: min(a.maxJsonDepth, b.maxJsonDepth),
        maxConcurrentRequests: min(
          a.maxConcurrentRequests,
          b.maxConcurrentRequests,
        ),
      );

  /// The limits as the `limits` member of `params` or `result`.
  ///
  /// All four, always — an absent member would mean "no request to lower this", and after a
  /// negotiation every limit *is* a decision, so a peer reading the answer has to be able to
  /// read all four without inferring the rest. §4's example carries three, which is why
  /// [fromJson] treats an absent member as the hard cap rather than as an error.
  JsonMap toJson() => JsonMap({
    'maxFrameBytes': maxFrameBytes,
    'maxHeaderBytes': maxHeaderBytes,
    'maxJsonDepth': maxJsonDepth,
    'maxConcurrentRequests': maxConcurrentRequests,
  });

  @override
  bool operator ==(Object other) =>
      other is SessionLimits &&
      other.maxFrameBytes == maxFrameBytes &&
      other.maxHeaderBytes == maxHeaderBytes &&
      other.maxJsonDepth == maxJsonDepth &&
      other.maxConcurrentRequests == maxConcurrentRequests;

  @override
  int get hashCode => Object.hash(
    maxFrameBytes,
    maxHeaderBytes,
    maxJsonDepth,
    maxConcurrentRequests,
  );

  @override
  String toString() =>
      'SessionLimits(maxFrameBytes: $maxFrameBytes, '
      'maxHeaderBytes: $maxHeaderBytes, maxJsonDepth: $maxJsonDepth, '
      'maxConcurrentRequests: $maxConcurrentRequests)';
}

/// The host's `api:` block, in the member names the product manifest uses.
///
/// [reference/config-schema.md] §1.2's four members and nothing else, and **all four are
/// ranges** — which is the observation that shapes this class. `extension: "1.0.0"` is the
/// range admitting exactly `1.0.0`, and `mcp: "2026-07-28"` is a date-shaped exact version
/// rather than a semver. That is why §4.4's grammar has a bare version, and why nothing here
/// is typed as a [ProtoVersion]: a `ProtoVersion` cannot hold `2026-07-28`, and the value in
/// the manifest is a range either way.
///
/// The host publishes this in the result of a successful handshake so a peer knows which
/// contract it is being held to without reading a file it may not have. It is the host's own
/// block, echoed — not a claim about the peer and not a subset of what the peer asked for.
final class HostApiVersions {
  /// Creates a host `api:` block, copying and freezing [ports].
  ///
  /// Not `const`, and that is forced by the copy: `JsonMap` is not `const` either for the same
  /// reason, and a value that aliases a mutable map a caller still holds is a `api.ports` that
  /// changes between the handshake and the diagnostic explaining it.
  ///
  /// A port name is `^[a-z][a-z0-9_]*$` and at most 32 characters — the Profile-name row of
  /// [concepts.md] §2, because a port name is one token with no namespace to qualify it. The
  /// names in the shipped manifest are `storage`, `memory` and `mcp`, and whatever a plugin
  /// declares; an invalid one is an [ArgumentError] naming it, because a port name that is not
  /// an identifier is a manifest error and this is where a manifest becomes a value.
  HostApiVersions({
    required this.protocol,
    required this.extension,
    required this.runtime,
    Map<String, ProtoVersionRange> ports = const {},
  }) : _ports = Map<String, ProtoVersionRange>.unmodifiable(ports) {
    for (final name in _ports.keys) {
      if (_isPortName(name)) continue;
      throw ArgumentError.value(
        name,
        'ports',
        'a port name is ^[a-z][a-z0-9_]*\$ and at most $_maxPortNameLength characters',
      );
    }
  }

  /// Reads a host `api:` block from [json].
  ///
  /// Strict, and strict in both directions: an unknown member is refused, a member that is not
  /// a string is refused, and a member that is not a range the grammar admits is refused. All
  /// three are `-32602` naming `$path.<member>`, because [InitializeResult.fromResult] reads a
  /// peer's answer to *our* handshake and a block we cannot check completely is a block we
  /// would be publishing a capability against.
  ///
  /// All four members are required, `ports` included. The alternative — an absent `ports`
  /// meaning "no ports" — was rejected for the reason §4.2 gives about `extensionApi`: a check
  /// that can be skipped by omitting its input is not a check, and this block is the input to
  /// §4.1's mandatory check. A host with no ports writes `"ports": {}`.
  factory HostApiVersions.fromJson(
    JsonMap json, {
    String path = r'$.result.api',
  }) {
    _rejectUnknownMembers(json, _apiMembers, path, 'api');
    ProtoVersionRange read(String name) {
      final value = json[name];
      if (value is! String) {
        throw _invalidParams(
          '$path.$name',
          'is ${_quoted(value)}, expected a version range as a string. All four `api` members '
              'are ranges, so a value here is a range even when it admits exactly one version',
        );
      }
      final range = ProtoVersionRange.parseOrNull(value);
      if (range == null) {
        throw _invalidParams(
          '$path.$name',
          'is ${jsonString(value)}, which is not a range this protocol writes. The grammar is '
              '`>=`, `>`, `<=`, `<`, `=` or a bare version, whitespace separated, and every '
              'comparator must hold',
        );
      }
      return range;
    }

    final portsMember = json['ports'];
    if (portsMember is! JsonMap) {
      throw _invalidParams(
        '$path.ports',
        'is ${_quoted(portsMember)}, expected an object mapping a port name to a version '
            'range',
      );
    }
    final ports = <String, ProtoVersionRange>{};
    for (final entry in portsMember.toMap().entries) {
      final name = entry.key;
      if (!_isPortName(name)) {
        throw _invalidParams(
          '$path.ports.$name',
          'is not a port name. A port name is ^[a-z][a-z0-9_]*\$ and at most '
              '$_maxPortNameLength characters',
        );
      }
      final value = entry.value;
      if (value is! String) {
        throw _invalidParams(
          '$path.ports.$name',
          'is ${_quoted(value)}, expected a version range as a string',
        );
      }
      final range = ProtoVersionRange.parseOrNull(value);
      if (range == null) {
        throw _invalidParams(
          '$path.ports.$name',
          'is ${jsonString(value)}, which is not a range this protocol writes',
        );
      }
      ports[name] = range;
    }

    return HostApiVersions(
      protocol: read('protocol'),
      extension: read('extension'),
      runtime: read('runtime'),
      ports: ports,
    );
  }

  /// The envelope wire version range, the one that has to match `meta.proto`.
  final ProtoVersionRange protocol;

  /// The contract every extension implements.
  final ProtoVersionRange extension;

  /// The `AlteriOneRuntime` handed to an extension.
  final ProtoVersionRange runtime;

  final Map<String, ProtoVersionRange> _ports;

  /// The version range of every port the host publishes, unmodifiable.
  Map<String, ProtoVersionRange> get ports => _ports;

  /// The block as the `api` member of a handshake result.
  JsonMap toJson() => JsonMap({
    'protocol': protocol.wire,
    'extension': extension.wire,
    'runtime': runtime.wire,
    'ports': _portsToJson(_ports),
  });

  @override
  bool operator ==(Object other) =>
      other is HostApiVersions &&
      other.protocol == protocol &&
      other.extension == extension &&
      other.runtime == runtime &&
      _mapEquals(other.ports, ports);

  @override
  int get hashCode => Object.hash(protocol, extension, runtime, ports.length);

  @override
  String toString() =>
      'HostApiVersions(protocol: $protocol, extension: $extension, '
      'runtime: $runtime, ports: ${ports.keys.join(', ')})';
}

/// The method name of the handshake, exactly as it appears on the wire.
///
/// A constant rather than a string literal at each use, because §1 says the namespace is set
/// by `module` *and* by the method, and the two have to agree: `core` plus `core.initialize` is
/// the only spelling this protocol defines, and [InitializeParams.asInitializeRequest]
/// compares against this rather than against a literal.
const String initializeMethod = 'core.initialize';

/// The `params` of a `core.initialize` request: what the peer offers.
///
/// §4's example, member for member, and every member of it is information the negotiation
/// cannot run without. The one exception is [limits], and §4.2 says why in one sentence: an
/// absent `limits` means "no request to lower anything", which is exactly the default.
///
/// No de-duplication and no defaulting in the constructor. The capability list is read as a set
/// — a duplicate is a peer's business, and inventing a rule about it here would be a rule
/// about something the protocol never mentions. The *host's* list is where membership is
/// decided, and [negotiateHandshake] is where a missing capability is reported.
final class InitializeParams {
  /// Creates a peer's offer, copying [capabilities] and [ports] into unmodifiable collections.
  ///
  /// A capability id is `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` and at most 64 characters —
  /// the Capability ID row of [concepts.md] §2, required to have at least one dot so that a
  /// bare token cannot be smuggled into a field a namespaced dispatcher reads. §4's example
  /// carries `web.search`, which is the shape; the vocabulary is not fixed by this version, so
  /// nothing here switches on a particular id.
  ///
  /// An invalid id is an [ArgumentError] naming it: this constructor is called with values the
  /// host has already validated, so a bad id here is a programming error rather than a peer's.
  /// The same value arriving over the wire is a `-32602` in [fromParams], and the two are kept
  /// apart precisely so neither is reported as the other.
  factory InitializeParams({
    required ProtoVersionRange protoVersionRange,
    required ProtoVersion moduleVersion,
    required List<String> capabilities,
    required ProtoVersion extensionApi,
    required Map<String, ProtoVersion> ports,
    SessionLimits? limits,
  }) {
    final frozen = List<String>.unmodifiable(capabilities);
    for (final capability in frozen) {
      if (_isCapabilityId(capability)) continue;
      throw ArgumentError.value(
        capability,
        'capabilities',
        'a capability id is ^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+\$ and at most '
            '$_maxCapabilityIdLength characters',
      );
    }
    final frozenPorts = Map<String, ProtoVersion>.unmodifiable(ports);
    for (final name in frozenPorts.keys) {
      if (_isPortName(name)) continue;
      throw ArgumentError.value(
        name,
        'ports',
        'a port name is ^[a-z][a-z0-9_]*\$ and at most $_maxPortNameLength characters',
      );
    }
    return InitializeParams._(
      protoVersionRange: protoVersionRange,
      moduleVersion: moduleVersion,
      capabilities: frozen,
      extensionApi: extensionApi,
      ports: frozenPorts,
      limits: limits,
    );
  }

  /// The `params` of a request this package has sent, or the shape [fromParams] reads.
  ///
  /// Throws [ProtocolViolation] of `-32602` when the frame is not an initialise request at
  /// all, and the same when it is one whose `params` do not match. The distinction matters
  /// because a dispatcher that asked the wrong question has a bug, while a peer that sent a
  /// malformed `params` is a `-32602` on the frame — and it is the reader's job to say which
  /// one happened.
  factory InitializeParams.fromParams(JsonMap params) {
    _rejectUnknownMembers(
      params,
      _initializeParamMembers,
      r'$.params',
      'params',
    );

    final rangeText = params['protoVersionRange'];
    if (rangeText is! String) {
      throw _invalidParams(
        r'$.params.protoVersionRange',
        'is ${_quoted(rangeText)}, expected a version range as a string',
      );
    }
    final range = ProtoVersionRange.parseOrNull(rangeText);
    if (range == null) {
      throw _invalidParams(
        r'$.params.protoVersionRange',
        'is ${jsonString(rangeText)}, which is not a range this protocol writes. The grammar '
            'is `>=`, `>`, `<=`, `<`, `=` or a bare version, whitespace separated, and every '
            'comparator must hold',
      );
    }

    final moduleVersion = _readVersion(
      params,
      'moduleVersion',
      'the manifest version, which is one of the two things being negotiated and cannot be '
          'left to the other number on the frame',
    );
    final extensionApi = _readVersion(
      params,
      'extensionApi',
      'the extension contract this peer implements',
    );

    final capabilitiesMember = params['capabilities'];
    if (capabilitiesMember is! JsonList) {
      throw _invalidParams(
        r'$.params.capabilities',
        'is ${_quoted(capabilitiesMember)}, expected an array of capability ids. A capability '
            'list of [] is a real state — most peers grant nothing — so it is spelled '
            'explicitly rather than inferred from an absent member',
      );
    }
    final capabilities = <String>[];
    for (final element in capabilitiesMember.toList()) {
      if (element is! String || element.isEmpty) {
        throw _invalidParams(
          r'$.params.capabilities',
          'holds ${_quoted(element)}, expected a non-empty capability id',
        );
      }
      if (!_isCapabilityId(element)) {
        throw _invalidParams(
          r'$.params.capabilities',
          'holds ${jsonString(element)}, which is not a capability id. One is '
              '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+\$ and at most $_maxCapabilityIdLength '
              'characters',
        );
      }
      capabilities.add(element);
    }

    final portsMember = params['ports'];
    if (portsMember is! JsonMap) {
      throw _invalidParams(
        r'$.params.ports',
        'is ${_quoted(portsMember)}, expected an object mapping a port name to a version',
      );
    }
    final ports = <String, ProtoVersion>{};
    for (final entry in portsMember.toMap().entries) {
      final name = entry.key;
      if (!_isPortName(name)) {
        throw _invalidParams(
          '\$.params.ports.$name',
          'is not a port name. A port name is ^[a-z][a-z0-9_]*\$ and at most '
              '$_maxPortNameLength characters',
        );
      }
      final value = entry.value;
      if (value is! String) {
        throw _invalidParams(
          '\$.params.ports.$name',
          'is ${_quoted(value)}, expected a version as a string',
        );
      }
      final version = ProtoVersion.parseOrNull(value);
      if (version == null) {
        throw _invalidParams(
          '\$.params.ports.$name',
          'is ${jsonString(value)}, expected major.minor.patch',
        );
      }
      ports[name] = version;
    }

    // `containsKey` and not a null check, for the same reason `SessionLimits.fromJson` uses it
    // and the reason `control.dart`'s `_readOptionalMessage` does: absent and present-and-null
    // are two different sentences from a peer, and §4.2 only defines the first one. Absent means
    // "no request to lower anything". `null` means the sender wrote a number-bearing object and
    // then wrote nothing into it, which is a bug in the sender and is reported as one rather
    // than absorbed as the default. Reading null as absent would make the negotiated limits
    // depend on a field's presence in a way no reader could predict.
    final limitsMember = params['limits'];
    SessionLimits? limits;
    if (params.containsKey('limits')) {
      if (limitsMember is! JsonMap) {
        throw _invalidParams(
          r'$.params.limits',
          'is ${_quoted(limitsMember)}, expected an object of limits. An absent `limits` means '
              'no request to lower anything, so a `null` here is a peer that wrote the member and '
              'then wrote nothing into it',
        );
      }
      limits = SessionLimits.fromJson(limitsMember);
    }

    return InitializeParams._(
      protoVersionRange: range,
      moduleVersion: moduleVersion,
      capabilities: List<String>.unmodifiable(capabilities),
      extensionApi: extensionApi,
      ports: Map<String, ProtoVersion>.unmodifiable(ports),
      limits: limits,
    );
  }

  InitializeParams._({
    required this.protoVersionRange,
    required this.moduleVersion,
    required this.capabilities,
    required this.extensionApi,
    required this.ports,
    required this.limits,
  });

  /// The peer versions this implementation of the envelope accepts.
  final ProtoVersionRange protoVersionRange;

  /// The peer's manifest version, which `meta.moduleVersion` must agree with.
  final ProtoVersion moduleVersion;

  /// The capabilities the peer asks for, in the order it listed them, unmodifiable.
  final List<String> capabilities;

  /// The extension contract this peer implements.
  final ProtoVersion extensionApi;

  /// The version of each port this peer needs, unmodifiable.
  final Map<String, ProtoVersion> ports;

  /// The limits the peer proposes, or null when it proposed none.
  final SessionLimits? limits;

  /// The `params` object.
  ///
  /// [limits] is **omitted** when null and every other member is always written. Omission
  /// rather than `null` for the reason [AlteriOneEnvelope.metaToJson] gives for its own
  /// optionals: a peer that receives `limits: null` has to decide whether that is "no limits"
  /// or "the sender did not know", and §4.2 has already decided it — absent means no request
  /// to lower anything. `capabilities` is present even when empty, because there the opposite
  /// is true: an empty list is a real state and an absent member would be a missing one.
  JsonMap toParams() {
    // A local, because `limits` is a public field and a public field cannot be promoted: Dart's
    // promotion is a promise that a name is not reassigned between the check and the use, and an
    // overridable getter is not that. Reading it once into a local is what makes the null check
    // and the call refer to the same value.
    final proposed = limits;
    return JsonMap({
      'protoVersionRange': protoVersionRange.wire,
      'moduleVersion': moduleVersion.toString(),
      // Already JSON: strings in, no copy needed, and `JsonList.trusted` says so rather than
      // letting a reader wonder whether the list was normalised.
      'capabilities': JsonList.trusted(capabilities),
      'extensionApi': extensionApi.toString(),
      'ports': _versionsToJson(ports),
      if (proposed != null) 'limits': proposed.toJson(),
    });
  }

  /// The request that carries these params.
  RequestEnvelope toEnvelope({
    required FrameId id,
    required String module,
    required EnvelopeMeta meta,
  }) => RequestEnvelope(
    id: id,
    module: module,
    method: initializeMethod,
    params: toParams(),
    meta: meta,
  );

  /// The params of [frame], or null when [frame] is not an initialise request.
  ///
  /// Null, not a throw, and for the same reason [EnvelopeType.fromWireName] returns null: a
  /// dispatcher switches on the method **first**, and `-32601` — "no such method" — belongs to
  /// the method registry that arrives with the dispatch task, not to a reader that has been
  /// handed a frame. A frame that *is* a `core.initialize` with bad `params` still throws, as
  /// `-32602`: the method matched, so the payload is what is being read.
  static InitializeParams? asInitializeRequest(AlteriOneEnvelope frame) {
    if (frame is! RequestEnvelope) return null;
    if (frame.method != initializeMethod) return null;
    return InitializeParams.fromParams(frame.params);
  }

  @override
  bool operator ==(Object other) =>
      other is InitializeParams &&
      other.protoVersionRange == protoVersionRange &&
      other.moduleVersion == moduleVersion &&
      other.extensionApi == extensionApi &&
      other.limits == limits &&
      _listEquals(other.capabilities, capabilities) &&
      _mapEquals(other.ports, ports);

  @override
  int get hashCode => Object.hash(
    protoVersionRange,
    moduleVersion,
    extensionApi,
    limits,
    capabilities.length,
    ports.length,
  );

  @override
  String toString() =>
      'InitializeParams(protoVersionRange: $protoVersionRange, '
      'moduleVersion: $moduleVersion, extensionApi: $extensionApi, '
      'capabilities: ${capabilities.length}, ports: ${ports.length}'
      '${limits == null ? '' : ', limits: $limits'})';
}

/// The `result` of a successful `core.initialize`: what the two sides agreed.
///
/// Four members and an invariant that is *not* among them. [HandshakeAccepted] is what
/// carries the [SessionVersionInvariant], and it is the only library code in the package that
/// builds one — an accepted result is what a host produces, and holding the invariant here as
/// well would give the value a second construction site that nothing gates.
final class InitializeResult {
  /// Creates the result of a negotiation.
  factory InitializeResult({
    required ProtoVersion negotiatedProtoVersion,
    required DegradePolicy degradePolicy,
    required SessionLimits limits,
    required HostApiVersions api,
  }) => InitializeResult._(
    negotiatedProtoVersion: negotiatedProtoVersion,
    degradePolicy: degradePolicy,
    limits: limits,
    api: api,
  );

  /// Reads the result of a peer's handshake.
  ///
  /// All five members required, and an unknown member refused as `-32602`. Both directions,
  /// because both are ways a peer can be wrong: a result missing a member has not said what was
  /// agreed, and one carrying a member this version does not define would have that member
  /// dropped — which is how a peer ends up believing a limit was agreed that was not.
  ///
  /// A result carrying `accepted: false` is refused with `-32600`
  /// ([JsonRpcErrorCode.invalidRequest]) and **not** with `-32602`, and the distinction is
  /// §4.2's: a peer that answers a handshake with a result saying it was not accepted "has
  /// neither agreed nor refused", and a session started from that value would be a session
  /// nobody agreed to. `-32602` would report a schema problem with a payload that is
  /// well-formed; `-32600` reports that the answer to *this request* is not an answer at all.
  /// Read before the other four, because a result that says `false` is not a result and the
  /// rest of it is not worth diagnosing.
  factory InitializeResult.fromResult(JsonMap result) {
    _rejectUnknownMembers(
      result,
      _initializeResultMembers,
      r'$.result',
      'result',
    );

    final accepted = result['accepted'];
    if (accepted is! bool) {
      throw _invalidParams(
        r'$.result.accepted',
        'is ${_quoted(accepted)}, expected a boolean. A peer that cannot say whether it agreed '
            'has not answered the handshake',
      );
    }
    if (!accepted) {
      throw ProtocolViolation(
        code: JsonRpcErrorCode.invalidRequest,
        message:
            '`\$.result.accepted` is false. A refusal is an `error` response and never a '
            'result, so a result saying the handshake was not accepted has neither agreed nor '
            'refused, and a session started from it is a session nobody agreed to (protocol.md '
            '§4.2)',
        path: r'$.result.accepted',
      );
    }

    final negotiated = _readVersion(
      result,
      'negotiatedProtoVersion',
      'the version both peers agreed on',
      at: r'$.result',
    );

    final policyText = result['degradePolicy'];
    final policy = DegradePolicy.fromWireName(policyText);
    if (policy == null) {
      throw _invalidParams(
        r'$.result.degradePolicy',
        'is ${_quoted(policyText)}, expected one of '
            '"${DegradePolicy.refuse.wireName}" or '
            '"${DegradePolicy.warnAndDegrade.wireName}". The policy is chosen and never '
            'inferred, so a value this version does not define is refused rather than '
            'defaulted',
      );
    }

    final limitsMember = result['limits'];
    if (limitsMember is! JsonMap) {
      throw _invalidParams(
        r'$.result.limits',
        'is ${_quoted(limitsMember)}, expected an object of the limits both sides are held to',
      );
    }
    final apiMember = result['api'];
    if (apiMember is! JsonMap) {
      throw _invalidParams(
        r'$.result.api',
        'is ${_quoted(apiMember)}, expected the host\'s `api` object',
      );
    }

    return InitializeResult(
      negotiatedProtoVersion: negotiated,
      degradePolicy: policy,
      limits: SessionLimits.fromJson(limitsMember, path: r'$.result.limits'),
      api: HostApiVersions.fromJson(apiMember),
    );
  }

  InitializeResult._({
    required this.negotiatedProtoVersion,
    required this.degradePolicy,
    required this.limits,
    required this.api,
  });

  /// The version both peers agreed on. Always the host's own.
  final ProtoVersion negotiatedProtoVersion;

  /// What the host does about a degradable disagreement.
  ///
  /// The **host's chosen** policy, echoed so the peer knows what it is in. That is the whole
  /// reason it is on the wire: a policy a peer cannot read is a policy a peer cannot decide
  /// whether to work around, and a peer that has to ask is a peer that has to be answered
  /// before it can act.
  final DegradePolicy degradePolicy;

  /// The limits both sides are held to: the per-field minimum, clamped to the hard caps.
  final SessionLimits limits;

  /// The host's `api:` block, so the peer knows the contract it is being held to.
  final HostApiVersions api;

  /// The `result` object.
  JsonMap toResult() => JsonMap({
    'accepted': true,
    'negotiatedProtoVersion': negotiatedProtoVersion.toString(),
    'degradePolicy': degradePolicy.wireName,
    'limits': limits.toJson(),
    'api': api.toJson(),
  });

  /// The response that carries this result.
  ResponseEnvelope toResponse({
    required FrameId id,
    required String module,
    required EnvelopeMeta meta,
  }) => ResponseEnvelope(
    id: id,
    module: module,
    meta: meta,
    body: ResultBody(toResult()),
  );

  @override
  bool operator ==(Object other) =>
      other is InitializeResult &&
      other.negotiatedProtoVersion == negotiatedProtoVersion &&
      other.degradePolicy == degradePolicy &&
      other.limits == limits &&
      other.api == api;

  @override
  int get hashCode =>
      Object.hash(negotiatedProtoVersion, degradePolicy, limits, api);

  @override
  String toString() =>
      'InitializeResult(negotiatedProtoVersion: $negotiatedProtoVersion, '
      'degradePolicy: ${degradePolicy.wireName}, limits: $limits, api: $api)';
}

/// Why a handshake was refused, or why one disagreement was degraded past.
///
/// Six causes, all of them version or capability disagreements, and all of them `-32050`
/// ([DomainErrorCode.versionIncompatible]) with the cause named in `error.data.reason` — a code
/// with an unreadable diagnostic next to it sends an operator looking for the wrong half of the
/// system.
enum HandshakeCause {
  /// The peer's `protoVersionRange` does not admit the version the host speaks.
  protoRangeUnsatisfied('proto_range_unsatisfied'),

  /// `meta.moduleVersion` and `params.moduleVersion` disagree, or the host's own published
  /// `api.protocol` does not admit the version it speaks.
  moduleVersionMismatch('module_version_mismatch'),

  /// The peer's `extensionApi` falls outside the host's `api.extension`.
  extensionApiOutOfRange('extension_api_out_of_range'),

  /// A port the peer declares is outside the host's published range for it.
  portVersionOutOfRange('port_version_out_of_range'),

  /// The peer declares a port the host does not publish at all.
  undeclaredPort('undeclared_port'),

  /// The peer asks for a capability the host does not publish.
  capabilityMismatch('capability_mismatch');

  const HandshakeCause(this.wireName);

  /// The value of `error.data.reason`.
  final String wireName;

  /// Whether a host whose policy is [DegradePolicy.warnAndDegrade] may continue past this.
  ///
  /// True for [capabilityMismatch] and nothing else, and that is a property of the **cause**
  /// rather than of configuration — which is the point §4.3 is making. A host that cannot
  /// speak the peer's version cannot usefully pretend to: there is no smaller version to fall
  /// back to that both sides would then agree on, and continuing would mean a session running
  /// on a version nobody agreed to, which §4.3 calls worse than a closed connection. A
  /// capability the host does not publish is different in kind — §5 permits `warn+degrade` for
  /// "an explicitly optional capability" — so the *policy* decides whether that one degrades,
  /// and the decision is recorded in the outcome as a warning rather than discarded.
  bool get degradable => this == HandshakeCause.capabilityMismatch;
}

/// What a negotiation concluded: agreed, or refused.
///
/// Sealed with exactly two cases, so a `switch` over an outcome is exhaustive and a third kind
/// of conclusion — "degraded, with warnings" is not one, it is [HandshakeAccepted] carrying
/// [HandshakeWarning]s — cannot be added without every handler failing to compile.
sealed class HandshakeOutcome {
  /// Creates an outcome. Only the two cases call this.
  const HandshakeOutcome();

  /// The response to send back, as a `result` or an `error` and never both.
  ///
  /// On the sealed base rather than duplicated per case, so a caller that already holds an
  /// [HandshakeOutcome] can answer a request without a cast — and so the §1 exclusivity is a
  /// property of the pair of implementations rather than a convention between them.
  ResponseEnvelope toResponse({
    required FrameId id,
    required String module,
    required EnvelopeMeta meta,
  });
}

/// The handshake was agreed, possibly with a disagreement the host's policy let past.
final class HandshakeAccepted extends HandshakeOutcome {
  /// Creates an accepted outcome, copying and freezing [warnings].
  HandshakeAccepted({
    required this.result,
    List<HandshakeWarning> warnings = const [],
  }) : warnings = List<HandshakeWarning>.unmodifiable(warnings);

  /// What was agreed.
  final InitializeResult result;

  /// The degradable disagreements the host's policy let through, in the order found.
  ///
  /// Recorded rather than discarded, because §4.3 requires the decision to survive: a session
  /// that continues with a capability the peer asked for and the host does not publish is only
  /// legitimate if somebody can afterwards read that it happened.
  final List<HandshakeWarning> warnings;

  /// The post-handshake invariant, and the only one **production** code here builds.
  ///
  /// `late final` rather than a getter so that it is one value: [SessionVersionInvariant] has
  /// no `==`, and a fresh instance per call would make two references to the same agreement
  /// unequal. A test may still build one to exercise `require` — the point is that no other
  /// *library* code does, so "an agreement happened" has exactly one source in this package.
  late final SessionVersionInvariant _invariant = SessionVersionInvariant(
    result.negotiatedProtoVersion,
  );

  /// The rule every frame in the session must obey from here on.
  SessionVersionInvariant get invariant => _invariant;

  @override
  ResponseEnvelope toResponse({
    required FrameId id,
    required String module,
    required EnvelopeMeta meta,
  }) => result.toResponse(id: id, module: module, meta: meta);

  @override
  String toString() =>
      'HandshakeAccepted(${result.negotiatedProtoVersion}'
      '${warnings.isEmpty ? '' : ', ${warnings.length} warning(s)'})';
}

/// One disagreement a `warn+degrade` host continued past.
///
/// Not an outcome and not a refusal: it is the record that the refusal did **not** happen, and
/// it carries a [HandshakeCause] so the same vocabulary a refusal uses describes the thing that
/// was allowed through.
final class HandshakeWarning {
  /// Creates a warning about [cause], explained by [detail].
  const HandshakeWarning({required this.cause, required this.detail});

  /// Which disagreement it was.
  final HandshakeCause cause;

  /// What disagreed, in one sentence. Never a value that could carry a secret.
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is HandshakeWarning &&
      other.cause == cause &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(cause, detail);

  @override
  String toString() => 'HandshakeWarning(${cause.wireName}: $detail)';
}

/// The handshake was refused. The session does not exist.
final class HandshakeRefused extends HandshakeOutcome {
  /// Creates a refusal.
  ///
  /// [peerVersion] and [hostVersion] are optional because a diagnostic sometimes needs
  /// neither — a port the host does not publish names a port, not a version — and a required
  /// pair would force a `??` that invents a version to fill the gap.
  const HandshakeRefused({
    required this.cause,
    required this.detail,
    this.peerVersion,
    this.hostVersion,
  });

  /// Which disagreement it was.
  final HandshakeCause cause;

  /// What disagreed, in one sentence. Never a value that could carry a secret.
  final String detail;

  /// The version the peer offered or implements, when the cause is about one.
  ///
  /// For [HandshakeCause.moduleVersionMismatch] this is the peer's `params.moduleVersion`, and
  /// the disagreement is **entirely inside the peer's own frame**: `meta.moduleVersion` is the
  /// other number and [hostVersion] is the host's, and neither is a party to that check. A reader
  /// comparing this pair to diagnose the failure is comparing the wrong two values.
  final ProtoVersion? peerVersion;

  /// The version this host speaks, when the cause is about one.
  ///
  /// Null for [HandshakeCause.moduleVersionMismatch], which is not about the host's version at
  /// all — the host was never asked.
  final ProtoVersion? hostVersion;

  /// The error this refusal is sent as.
  ///
  /// Always [DomainErrorCode.versionIncompatible] (`-32050`), **including a capability
  /// mismatch** — and that is §4.2's rule rather than a shortcut: the handshake negotiates and
  /// does not grant. Nothing is published before `accepted: true`, so at handshake time there
  /// is no capability to deny; a capability the host does not have is `-32042`, raised at the
  /// point the peer asks for one *after* the handshake. Answering `-32042` here would tell an
  /// operator that a policy denied something, when in fact nothing has been granted to deny yet.
  ///
  /// `data` carries the cause and the detail, plus both versions when they are known. `-32050`
  /// on its own is not actionable: the remedy is different for a version disagreement and a
  /// capability one, and `reason` is what tells them apart.
  AlteriOneError toError() => AlteriOneError(
    code: DomainErrorCode.versionIncompatible,
    message: '$initializeMethod refused: $detail',
    data: JsonMap({
      'reason': cause.wireName,
      'detail': detail,
      if (peerVersion != null) 'peerVersion': '$peerVersion',
      if (hostVersion != null) 'hostVersion': '$hostVersion',
    }),
  );

  @override
  ResponseEnvelope toResponse({
    required FrameId id,
    required String module,
    required EnvelopeMeta meta,
  }) => ResponseEnvelope(
    id: id,
    module: module,
    meta: meta,
    body: ErrorBody(toError()),
  );

  @override
  String toString() =>
      'HandshakeRefused(${cause.wireName}: $detail'
      '${peerVersion == null ? '' : ', peer $peerVersion'}'
      '${hostVersion == null ? '' : ', host $hostVersion'})';
}

/// What the host brings to a negotiation.
///
/// The three things a host chooses — its `api:` block, its degrade policy and the capabilities
/// it publishes — plus the two numbers it does not choose and may lower: the version it speaks
/// and the limits it will accept.
final class HostHandshake {
  /// Creates what this host offers, copying [capabilities] into an unmodifiable set.
  ///
  /// [protoVersion] is a nullable parameter defaulting to [ProtoVersion.current] rather than a
  /// defaulted one, and the reason is the SDK: a default value must be a constant, and
  /// [ProtoVersion.current] is a validated, lazily-initialised `final`. Going through null keeps
  /// [ProtoVersion.current] the single place the number lives — a host that does not name a
  /// version speaks the one this build speaks, which is the common case, and a host that must
  /// speak something else says so.
  ///
  /// Capabilities are validated exactly as [InitializeParams]'s are and become a **set**,
  /// because membership is the only question the negotiation asks of them and a duplicate in a
  /// host's own list is a configuration slip rather than something to preserve.
  HostHandshake({
    required this.api,
    required this.degradePolicy,
    required Iterable<String> capabilities,
    ProtoVersion? protoVersion,
    SessionLimits limits = SessionLimits.defaults,
  }) : _protoVersion = protoVersion ?? _defaultProtoVersion,
       capabilities = Set<String>.unmodifiable(_validated(capabilities)),
       limits = limits.capped;

  static final ProtoVersion _defaultProtoVersion = ProtoVersion.current;

  /// The host's `api:` block, echoed to the peer on success.
  final HostApiVersions api;

  /// The policy this host has chosen. Never inferred, never defaulted.
  final DegradePolicy degradePolicy;

  /// Every capability this host publishes, unmodifiable.
  ///
  /// What the peer may ask for. A capability missing from here is a mismatch, and under
  /// [DegradePolicy.warnAndDegrade] a warning rather than a refusal.
  final Set<String> capabilities;

  final ProtoVersion _protoVersion;

  /// The version this host speaks. Every frame it sends declares its major.
  ProtoVersion get protoVersion => _protoVersion;

  /// The limits this host accepts, already clamped to the hard caps.
  ///
  /// Clamped in the constructor rather than at the negotiation, so that a caller reading
  /// [limits] off a host is reading the effective value and cannot negotiate against a
  /// configuration number that was never in force.
  final SessionLimits limits;

  @override
  String toString() =>
      'HostHandshake(protoVersion: $protoVersion, '
      'degradePolicy: ${degradePolicy.wireName}, '
      'capabilities: ${capabilities.length}, limits: $limits)';
}

/// Runs the negotiation and returns what it concluded.
///
/// Six checks, in a fixed order, and the order is a diagnostic choice worth stating: a
/// module-version disagreement is a **more specific fact** than a range disagreement, so it is
/// reported first. A peer whose `meta.moduleVersion` and `params.moduleVersion` differ has not
/// said which version it is, and telling it that the range did not match would send it
/// looking at a constraint it may well satisfy.
///
/// | # | Check | Cause |
/// |---|---|---|
/// | 1 | `meta.moduleVersion` equals `params.moduleVersion` | `module_version_mismatch` |
/// | 2 | the peer's range admits the host's version | `proto_range_unsatisfied` |
/// | 3 | the host's `api.protocol` admits the host's version | `proto_range_unsatisfied` |
/// | 4 | `api.extension` admits the peer's `extensionApi` | `extension_api_out_of_range` |
/// | 5 | each port is declared, at an admitted version | see below |
/// | 6 | every requested capability is published | `capability_mismatch` |
///
/// Check 3 is the host's **self-check** against the range it publishes, and it is not
/// redundant. §1.2 calls `api.protocol` the envelope wire version range "matching `meta.proto`",
/// so a host whose own version falls outside the range it publishes is misconfigured; the
/// handshake is the only place a peer would find out, and finding out by not working is the
/// expensive way to be told. Reporting it as [HandshakeCause.protoRangeUnsatisfied] rather
/// than as a new cause is deliberate — to the peer it *is* an unsatisfiable range, and a sixth
/// cause would give `-32050` two spellings.
///
/// Check 5 has two causes, because a port the host does not publish at all and a port it
/// publishes at a version the peer is outside of are different mistakes with different
/// remedies. It walks the peer's own port map, in the peer's order, and stops at the first
/// disagreement: a peer that declares two bad ports has one first problem, and listing the
/// rest would be reporting guesses. Check 6 does the same, for the same reason.
///
/// What happens to a cause depends on two things and only two: whether it is
/// [HandshakeCause.degradable] — a property of the cause — and whether the host chose
/// [DegradePolicy.warnAndDegrade]. Both true means a [HandshakeWarning] and the handshake
/// continues; anything else is a refusal with the first cause found. A capability mismatch
/// under [DegradePolicy.refuse] refuses, which is the whole difference between the two
/// policies.
///
/// On acceptance the negotiated limits are
/// `SessionLimits.minimum(host.limits, params.limits ?? SessionLimits.defaults).capped`, so an
/// absent `params.limits` yields the host's own clamped limits — §4.2's "no request to lower
/// anything" taken literally, and a peer that omits the member gets its own proposal's default
/// back rather than a refusal. The negotiated version is always [HostHandshake.protoVersion]:
/// §4.3 refuses the "choose the highest version both could support" alternative, because that
/// needs a second version in this package to choose from.
///
/// Pure: no clock, no id generator, no `dart:io`, no ambient configuration. Everything it
/// reports comes from the three arguments, so the same inputs always produce the same outcome —
/// which is what makes a handshake testable without a real peer and a real network.
HandshakeOutcome negotiateHandshake({
  required InitializeParams params,
  required EnvelopeMeta meta,
  required HostHandshake host,
}) {
  final warnings = <HandshakeWarning>[];

  /// Records a warning and returns null, or returns the refusal to send.
  ///
  /// The whole degrade decision, in one place, so the rule is not restated per check. A cause
  /// only survives when the cause allows degrading **and** the host chose to; the two are
  /// separate conditions because a policy that could degrade a version disagreement would make
  /// a `warn+degrade` host a downgrade path, which §4.3 forbids.
  HandshakeRefused? consider(
    HandshakeCause cause,
    String detail, {
    ProtoVersion? peerVersion,
    ProtoVersion? hostVersion,
  }) {
    if (cause.degradable &&
        host.degradePolicy == DegradePolicy.warnAndDegrade) {
      warnings.add(HandshakeWarning(cause: cause, detail: detail));
      return null;
    }
    return HandshakeRefused(
      cause: cause,
      detail: detail,
      peerVersion: peerVersion,
      hostVersion: hostVersion,
    );
  }

  /// Records a refusal, unconditionally.
  ///
  /// What checks 1 to 5 use, and the reason they do not go through [consider] is that the
  /// fail-closed property must not depend on [HandshakeCause.degradable] continuing to read
  /// `false` for five separate values. Routing them through the degrade path makes that
  /// guarantee a property of an enum someone will eventually edit, and the failure mode of
  /// getting it wrong is the worst available one: a `null` where a refusal belongs, so a
  /// handshake crashes instead of refusing.
  ///
  /// Splitting the two makes the rule structural. Only check 6 can degrade, and only because
  /// [HandshakeCause.capabilityMismatch] is the one cause whose `degradable` is true — which is
  /// still a fact about the enum, but now one that gates a *warning* rather than a refusal.
  HandshakeRefused refuse(
    HandshakeCause cause,
    String detail, {
    ProtoVersion? peerVersion,
    ProtoVersion? hostVersion,
  }) {
    assert(
      !cause.degradable,
      'a check that cannot degrade routed a degradable cause to refuse; that cause belongs on '
      'the consider() path',
    );
    return HandshakeRefused(
      cause: cause,
      detail: detail,
      peerVersion: peerVersion,
      hostVersion: hostVersion,
    );
  }

  final hostVersion = host.protoVersion;

  // 1. The most specific fact first: a peer that sends two different versions for one handshake
  // has not said which one it is, and every later check would be reporting a consequence.
  //
  // Both versions named here are the *peer's*: `meta` is the peer's frame meta and
  // `params.moduleVersion` is the peer's own claim, so this disagreement is entirely inside one
  // frame and the host's version is not a party to it. Reporting the host's version as though
  // the peer had written it in `meta` would be a diagnostic that names the wrong number on the
  // one check whose whole purpose is that two numbers disagree.
  if (meta.moduleVersion != params.moduleVersion) {
    return refuse(
      HandshakeCause.moduleVersionMismatch,
      '`meta.moduleVersion` is ${meta.moduleVersion} and `params.moduleVersion` is '
      '${params.moduleVersion}. A peer that sends two different versions for one handshake has '
      'not said which version it is',
      peerVersion: params.moduleVersion,
    );
  }

  // 2. The peer's constraint against the version the host actually speaks.
  if (!params.protoVersionRange.allows(hostVersion)) {
    return refuse(
      HandshakeCause.protoRangeUnsatisfied,
      'the peer accepts ${params.protoVersionRange.wire} and this host speaks $hostVersion, '
      'which is not inside that range',
      peerVersion: params.moduleVersion,
      hostVersion: hostVersion,
    );
  }

  // 3. The host's self-check against the range it publishes. A misconfigured host is refused
  // here rather than left to fail in a way the peer cannot interpret.
  if (!host.api.protocol.allows(hostVersion)) {
    return refuse(
      HandshakeCause.protoRangeUnsatisfied,
      'this host speaks $hostVersion and publishes `api.protocol` '
      '${host.api.protocol.wire}, which does not admit it. A host outside the range it '
      'publishes is misconfigured, and a peer is not the place that gets found out',
      hostVersion: hostVersion,
    );
  }

  // 4. §4.1's mandatory extension check.
  if (!host.api.extension.allows(params.extensionApi)) {
    return refuse(
      HandshakeCause.extensionApiOutOfRange,
      'the peer implements `extensionApi` ${params.extensionApi} and this host publishes '
      '`api.extension` ${host.api.extension.wire}, which does not admit it. There is no '
      'unnegotiated downgrade: the child is not started on a version it guessed',
      peerVersion: params.extensionApi,
      hostVersion: hostVersion,
    );
  }

  // 5. §4.1's per-port check. The peer's own map order, and the first disagreement ends it.
  for (final entry in params.ports.entries) {
    final port = entry.key;
    final version = entry.value;
    final published = host.api.ports[port];
    if (published == null) {
      return refuse(
        HandshakeCause.undeclaredPort,
        'the peer declares the port `$port` and this host publishes no such port. A port the '
        'host does not declare is as fatal as one declared at the wrong version: both mean the '
        'peer was built against a contract this host does not have',
        peerVersion: version,
        hostVersion: hostVersion,
      );
    }
    if (!published.allows(version)) {
      return refuse(
        HandshakeCause.portVersionOutOfRange,
        'the peer declares the port `$port` at $version and this host publishes $published, '
        'which does not admit it',
        peerVersion: version,
        hostVersion: hostVersion,
      );
    }
  }

  // 6. Capabilities, in the order the peer asked for them, and the first one the host does not
  // publish decides. A capability the host *does* publish costs nothing to keep listing, so
  // only the missing one is named.
  for (final capability in params.capabilities) {
    if (host.capabilities.contains(capability)) continue;
    // **Not** `consider(...)!`. This is the one check whose cause is degradable, so `consider`
    // returns null here precisely when the host chose `warn+degrade` and the handshake is meant
    // to continue — a `!` here crashes the handshake it was supposed to let through, and it is
    // the only place in this function where a null is a normal return. Checks 1 to 5 use
    // [refuse], which cannot return null; this one continues the loop instead of returning, and
    // the two together are what makes the fail-closed rule structural rather than a promise
    // about an enum's values.
    final refusal = consider(
      HandshakeCause.capabilityMismatch,
      'the peer asks for the capability `$capability` and this host does not publish it. '
      'Nothing is published before `accepted: true`, so there is no capability to deny here; a '
      'capability asked for later is `-32042` at that later point',
      hostVersion: hostVersion,
    );
    if (refusal != null) return refusal;
    // Degraded: the warning is already recorded by `consider`. The peer asked for more than one
    // capability, so the rest are still worth checking — each is a separate question, and
    // reporting only the first would misdescribe what the session actually agreed to.
  }

  return HandshakeAccepted(
    result: InitializeResult(
      negotiatedProtoVersion: hostVersion,
      // The host's chosen policy, echoed rather than negotiated: the host speaks one version
      // and applies one policy, and telling the peer which is the whole point of the field.
      degradePolicy: host.degradePolicy,
      limits: SessionLimits.minimum(
        host.limits,
        params.limits ?? SessionLimits.defaults,
      ).capped,
      api: host.api,
    ),
    warnings: warnings,
  );
}

/// `^[a-z][a-z0-9_]*$` and at most 32 characters: a port name.
///
/// The Profile-name row of [concepts.md] §2, because a port name is one token with no
/// namespace to qualify it. Enumerated as a pattern and a length rather than left free so that
/// a manifest cannot introduce a spelling no reader of a port map agrees on.
final RegExp _portName = RegExp(r'^[a-z][a-z0-9_]*$');
const int _maxPortNameLength = 32;

/// `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` and at most 64 characters: a capability id.
///
/// The Capability ID row of [concepts.md] §2. The mandatory dot is what stops a bare token
/// from arriving in a field a namespaced dispatcher reads, and it is why this is not the same
/// pattern as a port name.
final RegExp _capabilityId = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');
const int _maxCapabilityIdLength = 64;

bool _isPortName(String value) =>
    value.length <= _maxPortNameLength && _portName.hasMatch(value);

bool _isCapabilityId(String value) =>
    value.length <= _maxCapabilityIdLength && _capabilityId.hasMatch(value);

/// Runs a constructor's capability check over an iterable, reporting the first failure.
Iterable<String> _validated(Iterable<String> capabilities) {
  final frozen = <String>{};
  for (final capability in capabilities) {
    if (!_isCapabilityId(capability)) {
      throw ArgumentError.value(
        capability,
        'capabilities',
        'a capability id is ^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+\$ and at most '
            '$_maxCapabilityIdLength characters',
      );
    }
    frozen.add(capability);
  }
  return frozen;
}

/// The four `limits` members, and what an absent one defaults to.
const _limitMembers = <String>{
  'maxFrameBytes',
  'maxHeaderBytes',
  'maxJsonDepth',
  'maxConcurrentRequests',
};

const _limitDefaults = <String, int>{
  'maxFrameBytes': hardMaxFrameBytes,
  'maxHeaderBytes': hardMaxHeaderBytes,
  'maxJsonDepth': hardMaxJsonDepth,
  'maxConcurrentRequests': hardMaxConcurrentRequests,
};

/// The four `api` members of [reference/config-schema.md] §1.2.
const _apiMembers = <String>{'protocol', 'extension', 'runtime', 'ports'};

/// The six `params` members of §4's example.
const _initializeParamMembers = <String>{
  'protoVersionRange',
  'moduleVersion',
  'capabilities',
  'extensionApi',
  'ports',
  'limits',
};

/// The five `result` members of §4's example.
const _initializeResultMembers = <String>{
  'accepted',
  'negotiatedProtoVersion',
  'degradePolicy',
  'limits',
  'api',
};

/// Refuses a member the object does not define.
void _rejectUnknownMembers(
  JsonMap json,
  Set<String> known,
  String path,
  String what,
) {
  for (final key in json.toMap().keys) {
    if (known.contains(key)) continue;
    throw _invalidParams(
      '$path.$key',
      'is not a member of a handshake `$what` in this version of the protocol. A member this '
          'version does not define would be dropped, and a silently dropped one is how two '
          'peers disagree about what was agreed',
    );
  }
}

/// Reads a required version member as a [ProtoVersion].
ProtoVersion _readVersion(JsonMap json, String name, String why, {String? at}) {
  final path = '${at ?? r'$.params'}.$name';
  final value = json[name];
  if (value is! String) {
    throw _invalidParams(
      path,
      'is ${_quoted(value)}, expected a version as a string',
    );
  }
  final version = ProtoVersion.parseOrNull(value);
  if (version == null) {
    throw _invalidParams(
      path,
      'is ${jsonString(value)}, expected major.minor.patch. It names $why, so a value this '
      'loose is not a version anyone can be held to',
    );
  }
  return version;
}

ProtocolViolation _invalidParams(String path, String what) => ProtocolViolation(
  code: JsonRpcErrorCode.invalidParams,
  message: '`$path` $what',
  path: path,
);

/// Names a member's value for a diagnostic.
///
/// A type name, not the value, exactly as `codec.dart` does it: `params` may carry a credential
/// and "expected a string, got a boolean" finds it while quoting the value puts it in a log.
/// The exceptions are the four places a *grammar* is being quoted — a range text and a
/// capability id are, by construction, a fixed alphabet with no room for a secret, and naming
/// the offending token is what §4.4's "refused with the offending token named" requires.
String _quoted(Object? value) {
  if (value == null) return 'absent';
  if (value is String) return jsonString(value);
  if (value is JsonMap) return 'an object';
  if (value is JsonList) return 'an array';
  return value.toString();
}

Map<String, Object?> _portsToJson(Map<String, ProtoVersionRange> ports) {
  final members = <String, Object?>{};
  for (final entry in ports.entries) {
    members[entry.key] = entry.value.wire;
  }
  return members;
}

Map<String, Object?> _versionsToJson(Map<String, ProtoVersion> ports) {
  final members = <String, Object?>{};
  for (final entry in ports.entries) {
    members[entry.key] = entry.value.toString();
  }
  return members;
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || b[key] != a[key]) return false;
  }
  return true;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The comparator half of a [ProtoVersionRange] token.
///
/// Private, and the range is the only thing that holds one: a caller that could reach a
/// comparator has to re-derive [ProtoVersion.compareTo] to use it, and a second comparison is
/// a second answer to "is this version inside".
final class _Comparator {
  factory _Comparator.parse(String token) {
    // Two characters tried before one, so `>=` is not read as `>` followed by `=1.0.0`. A token
    // with no recognised prefix is a bare version, and a bare version *means* `=` — which is a
    // meaning, not a prefix to strip, so the length removed is the length that matched and
    // nothing more. `forPrefix` rather than a pattern, because the operator set is closed and
    // enumerated next to this.
    final two = token.length >= 2 ? token.substring(0, 2) : '';
    final one = token.isEmpty ? '' : token.substring(0, 1);
    final prefix = _ComparatorOperator.forPrefix(two) != null
        ? two
        : (_ComparatorOperator.forPrefix(one) != null ? one : '');
    final operator = prefix.isEmpty
        ? _ComparatorOperator.equal
        : _ComparatorOperator.forPrefix(prefix)!;
    final text = token.substring(prefix.length);
    final version = ProtoVersion.parseOrNull(text);

    if (version == null) {
      // Ordering needs a precedence, and precedence is defined over a semver. A date is not
      // one, so `>=2026-07-28` is refused rather than guessed at.
      if (operator != _ComparatorOperator.equal) {
        throw FormatException(
          'the comparator ${jsonString(token)} orders by something that has no precedence. '
          'Only `major.minor.patch` can be ordered; a date-shaped version is exact or nothing',
          token,
        );
      }
      if (!_dateShaped.hasMatch(text)) {
        throw FormatException(
          'the comparator ${jsonString(token)} is not in the range grammar. A range is a '
          'whitespace-separated conjunction of `>=`, `>`, `<=`, `<`, `=` or a bare version, '
          'and every comparator must hold; a range outside the grammar is refused rather '
          'than partially understood',
          token,
        );
      }
    }
    return _Comparator._(operator, text, version);
  }

  const _Comparator._(this.operator, this._text, this._version);

  final _ComparatorOperator operator;

  /// The version token as written, which is also how `toString` renders it back.
  final String _text;

  /// The token parsed, or null when it is a date rather than a semver.
  final ProtoVersion? _version;

  /// Whether [candidate] satisfies this one comparator.
  bool holds(ProtoVersion candidate) {
    final version = _version;
    if (version == null) {
      // A date-shaped exact version, which today is `api.ports.mcp` and nothing else. No
      // [ProtoVersion] spells a date, so this admits nothing, and that is said here rather
      // than hidden: coercing `2026-07-28` into `2026.7.28` would put two spellings of one
      // version on the same boundary, which is the defect `version.dart` exists to prevent.
      // The consequence is that a peer declaring an `mcp` port with a semver version is
      // refused against a date-published range, until the MCP dialect adapter brings a version
      // type that can hold a date (protocol.md §7).
      return candidate.toString() == _text;
    }
    return switch (operator) {
      _ComparatorOperator.greaterOrEqual => candidate.compareTo(version) >= 0,
      _ComparatorOperator.greater => candidate.compareTo(version) > 0,
      _ComparatorOperator.lessOrEqual => candidate.compareTo(version) <= 0,
      _ComparatorOperator.less => candidate.compareTo(version) < 0,
      _ComparatorOperator.equal => candidate.compareTo(version) == 0,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is _Comparator &&
      other.operator == operator &&
      other._text == _text;

  @override
  int get hashCode => Object.hash(operator, _text);

  @override
  String toString() => '${operator.token}$_text';
}

/// `YYYY-MM-DD`: the one version this protocol admits that is not a semver.
///
/// Named here, and narrowly, because the manifest writes exactly one of them —
/// `api.ports.mcp: "2026-07-28"` — and a range has to be able to carry the value the manifest
/// states without a second spelling of it. A looser "any non-space token is an exact version"
/// was rejected: it would make `api.ports.mcp: "banana"` a valid published range, and this
/// package refuses values it cannot interpret rather than storing them.
///
/// **Shape, deliberately, and not a calendar.** The pattern checks that the token *looks* like a
/// date, so `2026-13-45` parses as one; what it cannot do is admit a [ProtoVersion], because
/// no version this package can hold spells a date either way. A calendar check would reject a
/// string without changing any outcome — both a real date and an impossible one admit nothing —
/// so it would be a rule about spelling rather than about meaning, and the one place such a
/// rule costs more than it buys is a manifest a human edits. The name says "date-shaped" for
/// exactly that reason: it describes the shape, and [ProtoVersionRange] documents the
/// consequence.
final RegExp _dateShaped = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// The five operators §4.4's grammar allows, with the prefix each is written as.
enum _ComparatorOperator {
  greaterOrEqual('>='),
  greater('>'),
  lessOrEqual('<='),
  less('<'),
  equal('=');

  const _ComparatorOperator(this.token);

  /// The spelling, and the value [_Comparator.parse] matches a token's prefix against.
  final String token;

  /// The operator written [prefix], or null.
  static _ComparatorOperator? forPrefix(String prefix) {
    for (final operator in _ComparatorOperator.values) {
      if (operator.token == prefix) return operator;
    }
    return null;
  }
}

/// Any run of whitespace, which is the separator the grammar declares.
///
/// `RegExp(r'\s+')` and not `split(' ')`, so a tab between two comparators is a separator
/// rather than part of the second token. Whitespace *inside* a token is still refused by
/// [_Comparator.parse], which is correct: a range with a stray newline is not a range, and
/// accepting it would make the whitespace that separates a `params` member from the next one
/// part of the value.
final RegExp _whitespace = RegExp(r'\s+');
