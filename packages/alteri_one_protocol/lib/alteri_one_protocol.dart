/// The versioned envelope, framing, codec and error taxonomy of the AlteriOne protocol.
///
/// This package is the contract between the core and an extension, and it is the only
/// contract an extension is given before it asks for anything. It is pure Dart: it never
/// imports `dart:io`, `dart:mirrors`, `dart:ffi` or a platform package, and the fact that
/// `alteri_one_platform` has a web implementation is what keeps that rule real rather than
/// aspirational — see [architecture/overview.md] §3.
///
/// ## What is here, and what is not
///
/// | Arrives with | What |
/// |---|---|
/// | task `0.4` | The envelope, its JSON codec, the version types and the error taxonomy |
/// | task `0.5` | Framing: `Content-Length`, the 8 MiB cap, the 8 KiB header cap, backpressure |
/// | task `0.6` | `$/cancelRequest`, `$/progress`, `core.initialize` and the session |
/// | tasks `0.7`, `0.8` | The in-process and stdio transports |
///
/// Nothing is declared before the task that specifies it, so that no declaration is written
/// twice or written against a spec that moved. In particular there is no `Session` here:
/// [SessionVersionInvariant] carries the post-handshake rule and is constructed by the handshake,
/// because a version agreement that has not happened cannot be represented as a value with a null
/// inside it. The framing limits do exist, because a frame's size has to be bounded before the
/// handshake that negotiates them — a cap that arrived *with* the negotiation would be a cap that
/// did not exist on the frames that negotiation was carried over.
///
/// ## The four things this library guarantees
///
/// - One envelope, four variants, and a `sealed` hierarchy so a handler is exhaustive.
/// - A response is exactly one of `result` or `error`, as a type rather than a rule.
/// - `id` is present on a request and a response and absent on a notification and an event, as
///   a constructor signature rather than a validation pass.
/// - `meta.proto` is an integer major and `meta.moduleVersion` is a semver, as two types that
///   cannot be built from one another's value.
///
/// Framing adds two more of the same kind. The boundary is a declared byte count, so a payload
/// containing `\r\n\r\n` is one frame and a frame arriving a byte at a time is one frame. And a
/// frame's size is bounded from its **header alone** — a peer that announces more than the cap
/// has cost the receiver forty bytes, not eight megabytes — which is why [FrameDecoder] checks
/// the number the header declares before it buffers any of the payload it claims.
///
/// The reasoning behind each, and the alternatives rejected, are in [ADR-0002],
/// [architecture/protocol.md] §1 and §2.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [reference/error-codes.md]: ../../../../docs/reference/error-codes.md
/// [ADR-0002]: ../../../../docs/decisions/0002-protocol-envelope.md
library;

export 'src/codec.dart' show decodeEnvelope, fromJsonMap;
export 'src/envelope.dart';
export 'src/error.dart';
export 'src/framing.dart';
export 'src/json.dart';
export 'src/version.dart';
