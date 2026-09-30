/// The refusal a platform port gives when the embed cannot provide it.
///
/// [architecture/build-and-release.md] §3 is the sentence this type exists to make executable:
///
/// > The `package:web` implementations exist because a browser client is a boundary the product
/// > supports, not because a core is ever expected to run in a tab; a browser-only embed, were
/// > one attempted, would have to **declare** storage, concurrency and secrets unavailable rather
/// > than approximate them.
///
/// Approximating is the failure. An in-memory storage that silently loses everything on reload,
/// a "concurrency" that runs everything on one isolate while reporting a parallelism of four, a
/// process host that accepts a spawn and then quietly does nothing: each of those is a caller
/// being told something false by a type that looked like it was telling the truth. A refusal is
/// the only honest answer, and this is the same rule the rest of the product already applies —
/// a sandbox that cannot be established refuses rather than degrading.
///
/// ## Why not `UnsupportedError`
///
/// [dart:core]'s own type is the obvious choice and it is the wrong one for a *port*:
///
/// - It carries no indication of **which** capability was missing, so the message has to be
///   parsed or the caller has to guess from context.
/// - It says the *operation* is unsupported, where this says the *platform* cannot provide it.
///   `System.identityHashCode` is not unsupported; the clock is unavailable.
/// - It is what `throw UnimplementedError` and `abstract` stubs already use, so a refusal from a
///   genuinely missing implementation is indistinguishable from a refusal from a deliberate one.
///   That distinction is the whole content of this file: "not built yet" and "cannot exist here"
///   are different answers and a caller may treat them differently.
///
/// ## What a caller is meant to do
///
/// Catch it where the capability was requested — at composition, at the edge of the embed — and
/// turn it into a stated configuration error. That is the composition root's job
/// ([architecture/overview.md] §4), and this type is what it catches. It is an [Exception] rather
/// than an [Error] because it is an ordinary, expected outcome of composing against a platform,
/// not a bug in the program.
///
/// The port name is a `String` and not a `Type` on purpose: naming a port with `Type` means this
/// library imports every port, so a new port drags the whole package into any consumer that only
/// wanted the name. The strings are checked against the port declarations by the contract test, so
/// a renamed port cannot leave a stale refusal behind.
///
/// [architecture/build-and-release.md]: ../../../../docs/architecture/build-and-release.md
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;

/// Thrown by a platform implementation that cannot exist on the platform it is running on.
///
/// Carries the [port] it was asked for and a [reason] a user can act on. Never thrown for a
/// capability that is merely missing from this build of the product — that is a wiring error in
/// the composition root, and it is reported as one.
final class PlatformUnavailable implements Exception {
  /// Creates a refusal for [port].
  ///
  /// [port] names the capability in the words the specification uses for it (`clock`, `paths`,
  /// `http`, `concurrency`, `process`, `storage`), and [reason] is a complete sentence naming the
  /// platform. The contract test asserts every refusal this package can produce uses one of those
  /// six names, because a refusal that cannot be attributed to a port is a refusal nobody can act
  /// on.
  PlatformUnavailable({required this.port, required this.reason});

  /// The capability that was asked for, e.g. `process`.
  final String port;

  /// Why this platform cannot provide it, in one sentence.
  final String reason;

  @override
  String toString() =>
      'PlatformUnavailable($port): $reason '
      'This is a refusal, not a fallback: the capability is declared unavailable rather than '
      'approximated, so nothing downstream has to work out whether the result was real.';
}

/// Refuses with a [PlatformUnavailable] and never returns.
///
/// The one-line body every web implementation uses, so the refusal a caller sees is the same
/// wherever it was raised from — the alternative, a throw written out at each of a dozen call
/// sites, is a dozen places for the wording to drift and for one of them to return a plausible
/// default instead.
///
/// Typed `Never` rather than `void` so it can stand in a `=>` expression and satisfy a member whose
/// declared return type is a value: an arrow body that throws returns `Never`, and a
/// `Never`-returning method is a valid implementation of a member that returns something else.
/// Not generic for the same reason — it is only ever called in a `Never` position, and a type
/// parameter here could only be inferred as `Never` or not at all.
Never refuse({required String port, required String reason}) =>
    throw PlatformUnavailable(port: port, reason: reason);
