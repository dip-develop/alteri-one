/// The server-sent-events reader, and the two framing facts that make it correct.
///
/// [architecture/providers.md] §3.2 assembles a tool call from *"a chunk sequence"* of a
/// streaming endpoint, and says the deltas arrive *"split across chunks at arbitrary byte
/// boundaries"*. So this file is not incidental plumbing: it is the place where §3.2's worst
/// stated failure mode — an argument JSON split at a byte nobody chose — either becomes a correct
/// assembly or a `-32700`.
///
/// ## Why the reader is incremental and not a `split`
///
/// A `data: {...}\n\n` stream invites `body.split('\n\n')`, and that is wrong twice over. It
/// assumes the body has arrived, which is exactly what §3 forbids (first tokens must reach the
/// CLI while the model is still writing); and it assumes the separator is two newlines, which is
/// true of an endpoint that obeys the letter of the SSE grammar and false of several that do not
/// — `dart:io`'s own chunk boundaries, a proxy that rewrites line endings, a Windows-authored
/// fixture. So this is a state machine fed one byte range at a time and it holds partial state
/// across calls.
///
/// ## The two traps, and both of them have bitten a framing implementation in this repository
///
/// **A CRLF block terminator splits into two empty lines, not one.** `a\r\n\r\n`.split('\r\n')
/// is `['a', '', '']` — the blank line *and* an artefact of the split. An implementation that
/// dispatches on every blank line therefore dispatches **twice**: once correctly and once with
/// an empty payload. The symptom is not a crash; it is a spurious extra event on every frame,
/// which for a tool-call delta is an extra empty fragment.
///
/// Two things in [SseReader] guard that, and it is worth being precise about which does the work
/// because getting it backwards is how a reader ends up "fixing" the wrong one. The **non-empty
/// guard** on dispatch is the one that saves it: a second blank line has nothing accumulated, so
/// it dispatches nothing. Consuming the terminator *including* its line ending is the other half,
/// and it is what makes a `CRLF` and an `LF` endpoint behave identically rather than one of them
/// producing an extra event per frame. Both are needed; the first is the load-bearing one.
///
/// **A payload spanning chunks must be compared against the outstanding bytes, never against the
/// declared length.** That was the protocol framing's version of the same mistake and it emitted
/// every multi-chunk frame one bufferful short. Here the equivalent is subtler: a chunk boundary
/// that falls **inside a multi-byte UTF-8 character**. The bytes are accumulated and decoded with
/// a streaming decoder rather than per chunk, so a character that straddles a boundary is
/// decoded once, from the joined bytes, instead of raising a `FormatException` on the first half
/// and losing a byte on the second.
///
/// [architecture/providers.md]: ../../../../../docs/architecture/providers.md
library;

import 'dart:async';
import 'dart:convert';

/// The carriage return, a line terminator in the SSE grammar on its own.
const int _cr = 0x0d;

/// The line feed, a line terminator, and the second half of a `CRLF` pair.
const int _lf = 0x0a;

/// One decoded server-sent event: its `data` payload and whatever named fields came with it.
///
/// `data` is **already joined**, because the SSE grammar says a field may appear on several
/// consecutive lines and their values are concatenated with `\n`. A reader that took the last
/// `data:` line would silently truncate any event an endpoint wrapped.
///
/// The named fields are kept because an endpoint is allowed to send them and dropping them would
/// mean a `retry:` hint or an `event:` name reached nothing. Nothing in this product acts on
/// them today, which is documented at the fields rather than left as an unexplained gap.
final class SseEvent {
  /// Creates an event with [data] and the named [fields].
  const SseEvent(this.data, [this.fields = const <String, String>{}]);

  /// The joined `data:` payload, with no trailing newline.
  final String data;

  /// The `event:`, `id:` and `retry:` values, keyed by field name, in arrival order of the names.
  final Map<String, String> fields;
}

/// The incremental reader: feed it bytes, take events.
///
/// A state machine over **three** states — *outside a line*, *inside a line*, *inside an event* —
/// and the third exists only so that the line terminator itself can be recognised. `CR`, `LF` and
/// `CRLF` are all line terminators in the grammar, and a line terminator is a two-character
/// sequence, so "am I inside a line" cannot be answered without knowing whether the `\r` just seen
/// was a terminator or the first half of one. [_afterCarriageReturn] is that knowledge, and it is
/// the only reason a reader this small needs a field at all.
class SseReader {
  /// Creates a reader.
  ///
  /// [maxLineBytes] bounds one line. A `data:` line carrying a tool call's argument fragment can
  /// legitimately be large, and a bound that was too small would be a cap the product imposes on
  /// a model it does not control; too large and a hostile or broken endpoint can grow this
  /// reader's buffer without limit. One mebibyte is the middle: larger than any argument object
  /// a tool schema admits, and small enough that exhausting it is a reportable fault rather than
  /// an out-of-memory condition.
  SseReader({this.maxLineBytes = 1024 * 1024});

  /// The bound on a single line, in bytes of UTF-8.
  final int maxLineBytes;

  final StringBuffer _line = StringBuffer();
  final List<String> _data = <String>[];
  final Map<String, String> _fields = <String, String>{};

  /// Whether the previous character was a `CR`, so a following `LF` is the same terminator.
  bool _afterCarriageReturn = false;

  /// The bytes currently held in [_line], to enforce [maxLineBytes].
  int _lineBytes = 0;

  /// Feeds [chunk] and returns every event it completed.
  ///
  /// A `List` rather than a `Stream` because the natural caller is `transform`, whose contract is
  /// exactly this: bytes in, values out, no second stream to keep in step. Returns an empty list
  /// for the overwhelming majority of calls, which is what a partial line looks like.
  List<SseEvent> add(String chunk) {
    final events = <SseEvent>[];
    for (var i = 0; i < chunk.length; i++) {
      final unit = chunk.codeUnitAt(i);
      if (_afterCarriageReturn) {
        // A `LF` right after a `CR` is the *same* terminator. Consuming it here rather than
        // treating it as a second one is the whole of the CRLF trap: exactly one empty line is
        // produced per block terminator, so a `data: x\r\n\r\n` block dispatches once.
        _afterCarriageReturn = false;
        if (unit == _lf) continue;
      }
      if (unit == _cr) {
        _afterCarriageReturn = true;
        _endLine(events);
        continue;
      }
      if (unit == _lf) {
        _endLine(events);
        continue;
      }
      _afterCarriageReturn = false;
      _lineBytes += unit <= 0x7f ? 1 : _utf8Width(unit);
      if (_lineBytes > maxLineBytes) {
        throw SseFormatException(
          'an SSE line grew past the ${maxLineBytes}-byte cap without a terminator',
        );
      }
      _line.writeCharCode(unit);
    }
    return events;
  }

  /// Closes the line currently being accumulated, and dispatches an event on a blank one.
  void _endLine(List<SseEvent> out) {
    if (_line.isEmpty) {
      // A blank line ends the block. Dispatch **only** when there is something to dispatch, so a
      // leading blank line — which several endpoints send as a preamble — is not an empty event.
      if (_data.isNotEmpty || _fields.isNotEmpty) {
        out.add(SseEvent(_data.join('\n'), Map<String, String>.of(_fields)));
        _data.clear();
        _fields.clear();
      }
      return;
    }

    final line = _line.toString();
    _line.clear();
    _lineBytes = 0;

    if (line.startsWith(':'))
      return; // A comment, and a comment is not a terminator.

    final colon = line.indexOf(':');
    final String field;
    String value;
    if (colon < 0) {
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      // **Exactly one leading space is stripped, and only one.** The grammar says a single
      // optional space follows the colon; `data:  x` is the payload `" x"` and not `"x"`. A
      // `trim()` here would corrupt a tool argument that legitimately begins with a space, and
      // it would do so invisibly — the JSON still parses and the string is wrong.
      if (value.startsWith(' ')) value = value.substring(1);
    }

    // **`data` and the named fields are one switch and not two**, and the reason is that a
    // `data:` line has to be *appended* (the grammar concatenates) while a named field is
    // *replaced* (the grammar says the last one wins). Two switches would have had to agree on
    // the field name, and the disagreement would be a duplicated string.
    //
    // The `case` bodies need no `break`: Dart 3 terminates a `switch` statement's cases
    // implicitly and the analyzer rejects a body that falls through, so the omission is checked
    // rather than remembered. That is the same argument `testing-strategy.md`'s sealedness note
    // makes — prefer the form the compiler proves over a test that re-checks it.
    switch (field) {
      case 'data':
        _data.add(value);
      case 'event':
      case 'id':
      case 'retry':
        _fields[field] = value;
      default:
        // An unknown field is ignored, per the grammar, and deliberately not reported: the field
        // set is extensible and an endpoint adding one is not a fault in this product.
        break;
    }
  }

  /// How many UTF-8 bytes the code unit at [unit] contributes to [maxLineBytes].
  ///
  /// **A surrogate pair counts 4, not 8.** This walks *code units*, and a character outside the
  /// BMP arrives as two of them: an earlier version charged 4 to each and so tripped the
  /// one-mebyte line bound at roughly half a mebibyte of real bytes on an emoji-heavy line, which
  /// made [maxLineBytes] a bound on something other than what its documentation says it is. A
  /// trail surrogate is therefore worth 0 and the lead 4.
  ///
  /// Read from the lead unit's own range rather than from a table, because the count only matters
  /// for a bound an endpoint would have to exceed by a megabyte, and a table would be four cases
  /// to answer it. A continuation unit standing alone is charged 2: a malformed sequence is
  /// caught by the decoder, and this only has to be a defensible upper bound, not a diagnosis.
  static int _utf8Width(int unit) {
    if (unit >= 0xd800 && unit <= 0xdbff)
      return 4; // A lead surrogate: the pair is 4 bytes.
    if (unit >= 0xdc00 && unit <= 0xdfff)
      return 0; // A trail surrogate: already counted.
    if (unit < 0x80) return 1;
    if (unit < 0x800) return 2;
    if (unit < 0x10000) return 3;
    return 4;
  }
}

/// A stream that is not a well-formed server-sent event stream.
///
/// Carries the **wire** code rather than a `FormatException`, because §1 says transport errors are
/// mapped into the taxonomy and a caller should not have to recognise three exception types to
/// find out that a turn failed. `-32700` is the honest one: the bytes arrived and were not
/// parseable as the thing the endpoint said they were.
class SseFormatException implements Exception {
  /// Creates the exception.
  SseFormatException(this.message);

  /// What was wrong, in one sentence that names no credential.
  final String message;

  @override
  String toString() => 'SseFormatException($message)';
}

/// Decodes [body] as UTF-8 **across chunk boundaries**, yielding strings.
///
/// The reason this exists rather than `utf8.decode(bytes)` per chunk is the second trap in this
/// file's documentation: a chunk boundary inside a multi-byte character. `utf8.decoder` as a
/// stream transformer keeps the partial sequence in its own state and emits the character once the
/// remaining bytes arrive, so a boundary at any offset is invisible. Converting each chunk
/// independently would raise on the first half and, in a reader that swallowed it, silently drop
/// a byte and corrupt every character after it.
///
/// [allowMalformed] is off. A truncated multi-byte character at the end of a stream is a
/// truncated response, and `allowMalformed: true` would turn it into a U+FFFD and let a turn
/// complete with a reply that has a replacement character in it — which reads to a user as the
/// model saying something odd, rather than as a network fault.
Stream<String> decodeUtf8Chunks(Stream<List<int>> body) =>
    body.transform(const Utf8Decoder());
