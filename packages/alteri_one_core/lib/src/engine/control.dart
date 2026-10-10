/// The control primitives a run is bound by: its deadline, its cost budget, its step limit and
/// its stagnation detector — and the cancellation token, which is somebody else's type.
///
/// [architecture/engine.md] §3 states the invariants. §3.2 states what each primitive **is**,
/// and this file is that section in Dart: four of the five can each be written two plausible
/// ways, and which of the two is in the file decides whether §3 holds while a run is going. So
/// §3.2 is the contract, every refusal below is one of its decisions, and wherever this file has
/// a judgement call of its own the comment says so and names the alternative it rejected.
///
/// ## The ways to get each of these wrong
///
/// - **A deadline compared against the wall clock.** [AlteriOneClock] has two sources of time
///   for exactly this reason. [Deadline] reads [AlteriOneClock.monotonicNow] and never
///   [AlteriOneClock.now]; a wall clock can jump backwards, and a deadline compared against one
///   extends itself the moment NTP corrects the host.
/// - **A per-call timeout that is the child's own.** [Deadline.child] is `min(perCall,
///   remaining)`. §5.1's "the effective child time is `min(configured child deadline, parent
///   remaining)`" is the same rule one level up, and a per-call timeout larger than what is left
///   is **not** an error: it becomes the time that is left, and the run is what ends it.
/// - **A ceiling treated as a reservation.** [CostBudget] checks an estimate before the call and
///   counts the reported usage after it, so a turn that costs more than it estimated leaves the
///   ledger over its ceiling. A budget that clamped at the ceiling would be reporting the plan
///   rather than the spend.
/// - **The token figure derived from the USD one.** Both are ceilings and either can end the run,
///   so a run with a generous USD ceiling and a tight token ceiling stops on tokens.
/// - **A reserve that mints.** §5.1's shared ledger means a reserve withholds from the parent and
///   does nothing else, and a reserve that is never returned is the parent's budget drifting
///   downwards for a run that spent nothing.
/// - **A step limit counting tool calls.** §3.1: one step is one **model turn**, counted once
///   however many tool calls that turn asked for.
/// - **A detector that resets on success.** §3.1: "a successful `ToolOutcome.ok` does **not**
///   reset it — the loop, not the outcome, is the signal". [StagnationDetector] therefore has no
///   member that takes an outcome at all, so the rule is the shape of the type rather than a flag
///   somebody has to remember to clear.
/// - **A second cancellation signal.** §3.2: `CancelToken` is the protocol package's,
///   re-exported, not reimplemented — see the export at the top of this file.
/// - **A terminal control outcome handed back as a tool outcome.** §3.2: `-32030`/`-32031`/`-32032`
///   end the run. [RunStopReason] is a closed union over the four controls and nothing in it
///   takes a tool's result, so no tool can produce one.
///
/// ## What this file does not have
///
/// No clock, no id source and no random source of its own. Every value below comes from the
/// arguments or from the injected [AlteriOneClock], so a run's control decisions replay exactly —
/// see [process/testing-strategy.md] §3. Token totals are [provider.dart]'s: [AlteriOneUsage] is
/// reused as it is, [AlteriOneUsage.totalTokens] is read rather than re-derived, and
/// `AlteriOneUsage.operator +` is how a run's ledger accumulates.
///
/// ## The digest, and why it is here
///
/// §3.1 fixes the stagnation signature as `SHA-256(toolId ‖ canonicalArgsJson)`, and there is no
/// `package:crypto` in this package's dependency graph — adding one is a change to the root
/// manifest *and* to the dependency table the workspace contract test holds, so it is not one
/// file's decision to make. SHA-256 is therefore implemented privately at the bottom of this file,
/// in pure Dart with every intermediate masked to 32 bits so it is exact on the VM and in a web
/// build alike. It is private and it is the *specification's own function*, not a substitute for
/// it: a contract test pins it against the published FIPS 180-4 vectors, and the day a second
/// caller needs a digest — task `0.16`'s transcript digest, §2's `argumentDigest` — it moves to one
/// shared internal rather than being written a second time.
///
/// [architecture/engine.md]: ../../../../../docs/architecture/engine.md
/// [architecture/overview.md]: ../../../../../docs/architecture/overview.md
/// [reference/error-codes.md]: ../../../../../docs/reference/error-codes.md
/// [process/testing-strategy.md]: ../../../../../docs/process/testing-strategy.md
library;

import 'dart:convert';

import 'package:alteri_one_platform/alteri_one_platform.dart';
import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import '../provider.dart';

/// The cancellation signal, re-exported rather than reimplemented — §3.2's decision.
///
/// `CancelToken` already cascades, already keeps the first reason and already tells a late
/// listener from an early one, all in the protocol package where the framing that produces a
/// `$/cancelRequest` also lives. A second type here would be a second signal with subtly
/// different semantics, and composing the two would be undefined: a tool handed the core's token
/// would ignore the peer's cancel. The export is what makes that impossible — there is one
/// `CancelToken` type in the product and this file does not get to name it differently.
export 'package:alteri_one_protocol/alteri_one_protocol.dart'
    show CancelReason, CancelToken;

/// A run's time limit, and the per-call limits derived from it.
///
/// ## Always finite, and why that is a type rather than a convention
///
/// §3: "Every run has a mandatory finite `Deadline`. `Infinity` and "no timeout" are not accepted
/// values." Dart has no infinite `Duration`, so "no timeout" can only be spelled as a sentinel —
/// [Duration.zero], or a duration so long it is a lie — and the factory refuses the first and
/// every non-positive value. A caller that means "unlimited" has said something §3 does not
/// permit, and the only way to let it through would be a `Duration? limit` that some later
/// `null` check has to remember to honour.
///
/// ## Monotonic, always
///
/// [isExpired] and [remaining] both come from [AlteriOneClock.monotonicNow]. The wall clock can
/// jump in either direction — NTP, a timezone change, a laptop resuming from sleep — and a
/// deadline compared against one extends itself when it happens. [startedAt] is therefore a
/// *record* for the transcript and is never subtracted from anything; a `DateTime` and a
/// `Duration` are different types precisely so that the two cannot be confused. The run's zero is
/// instead the **monotonic reading captured when this deadline was constructed**, which is not
/// necessarily `Duration.zero`: `monotonicNow` is documented as relative to an arbitrary origin,
/// so a clock may be anywhere in its own timeline, and a deadline measured from the raw reading
/// would be born expired on it.
///
/// [FakeClock] resolves through the import below — it is exported from the platform package's own
/// barrel, so naming this package's `src/` path here would have been a relative link into another
/// package, and one that breaks when that package moves a private file.
final class Deadline {
  /// Creates a deadline of [limit] from [startedAt], reading time from [clock].
  ///
  /// Throws [ArgumentError] naming `limit` when it is zero or negative. §3.2: "A `Duration`
  /// argument of zero or less is refused at construction rather than producing a deadline that
  /// has already expired, since a caller that meant "unlimited" has said something the run does
  /// not permit."
  ///
  /// [startedAt] is converted to UTC, for the reason [FakeClock] converts its own: a local
  /// `DateTime` would put a zone offset into every transcript line the run produces, and the
  /// local-time decision belongs at the edge ([AlteriOneClock.now] is UTC for the same reason).
  factory Deadline({
    required AlteriOneClock clock,
    required DateTime startedAt,
    required Duration limit,
  }) {
    if (limit <= Duration.zero) {
      throw ArgumentError.value(
        limit,
        'limit',
        'a run deadline is a positive duration. engine.md §3 refuses Infinity and "no timeout" '
            'as values, and a zero or negative limit is the only spelling either could take '
            'here',
      );
    }
    return Deadline._(
      clock: clock,
      startedAt: startedAt.toUtc(),
      limit: limit,
      origin: clock.monotonicNow(),
    );
  }

  const Deadline._({
    required AlteriOneClock clock,
    required DateTime startedAt,
    required Duration limit,
    required Duration origin,
  }) : _clock = clock,
       _startedAt = startedAt,
       _limit = limit,
       _origin = origin;

  final AlteriOneClock _clock;
  final DateTime _startedAt;
  final Duration _limit;

  /// The clock's monotonic reading when this deadline was created, and therefore this run's zero.
  ///
  /// Not the same instant as [startedAt], and deliberately so. `monotonicNow` is documented as
  /// "relative to an arbitrary origin chosen by the implementation", so a clock handed to a run
  /// may be anywhere in its own timeline — and a deadline compared against the raw reading is born
  /// expired on any such clock, which in production means every run failing instantly and in a
  /// test that happens to use a zero-based clock never noticing. Subtracting the reading captured
  /// here is what makes `remaining` mean *since this run started* rather than *since this clock
  /// was created*.
  ///
  /// [startedAt] stays a `DateTime` and stays a record: a wall-clock instant has no place in a
  /// subtraction against a monotonic `Duration`, and conflating the two is the mistake this field
  /// exists to make impossible.
  final Duration _origin;

  /// When the run started, in UTC. A record for the transcript, not an input to any comparison.
  DateTime get startedAt => _startedAt;

  /// The whole run's limit, as configured.
  Duration get limit => _limit;

  /// Whether the whole run has run out of time.
  ///
  /// `monotonicNow() >= limit`, read from [AlteriOneClock.monotonicNow] and never from
  /// [AlteriOneClock.now]. `>=` and not `>` so that a run whose limit has exactly elapsed reports
  /// expired rather than one microsecond past a boundary it has in fact crossed.
  bool get isExpired => _elapsed >= _limit;

  /// How much of the run is left, never negative and zero once [isExpired].
  ///
  /// Clamped at zero rather than allowed to go negative, because a caller reads this to decide
  /// what to hand a child and to print in `task_done`, and a negative "you have -4s left" is a
  /// number no caller can use. The clamp loses the overshoot deliberately: the overshoot is not
  /// information, it is the loop noticing late.
  Duration get remaining {
    final left = _limit - _elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// A per-call deadline of `min(perCall, remaining)`, sharing this deadline's clock.
  ///
  /// ## A child can never extend its parent
  ///
  /// §3.2: "a 30-second model timeout inside a run with 4 seconds remaining is a **4-second**
  /// model timeout, and the run is what ends it." A per-call timeout larger than what is left is
  /// therefore not an error and not a warning — it becomes the remaining time. §5.1 states the
  /// same rule for a subagent's configured deadline, and that is why the clamp is in this type
  /// rather than at each call site: §3's "model, tool and subagent cannot bypass the deadline
  /// through an internal API" holds because there is no way to ask for a child that outlives the
  /// parent, not because three call sites each remembered.
  ///
  /// Throws [ArgumentError] naming `perCall` when it is zero or negative, for §3.2's reason.
  ///
  /// ## An exhausted parent yields the smallest legal child, not a throw
  ///
  /// An earlier version threw [StateError] here on the reasoning that "the loop checks [isExpired]
  /// before it starts a turn (§2 checks it before every step), so this is a caller that skipped
  /// that check". **§2's own pseudocode takes this path.** Its loop checks `isExpired` and then
  /// `await`s a policy evaluation before reaching `deadline.child(...)`, so a run whose model turn
  /// consumes 9.9 s of a 10 s budget and whose approval prompt takes the last 0.1 s arrives here
  /// with nothing left. The check and the call are not adjacent, so "the caller skipped the check"
  /// was true only of a caller that was never written.
  ///
  /// A throw there is worse than a very short deadline: §3 says an expired deadline is
  /// `Timeout(Duration.zero)`, and a [StateError] leaving the loop is neither one of §2's four
  /// terminal outcomes nor a result — it is a crash, on the run's own timeout path. So an
  /// exhausted parent yields [Duration] **1µs** worth of child: the smallest duration that is not
  /// the zero §3.2 refuses at construction, and one on which no work can complete. The child
  /// expires on that microsecond and the loop's next boundary reports the timeout, which is what
  /// §3 names and where §2 intended to be.
  ///
  /// "A child can never extend its parent" still holds in the only sense that has teeth: a child
  /// never grants itself time the parent had. A microsecond is not time, it is the shortest legal
  /// way to say *already over* in a type that will not represent zero.
  Deadline child(Duration perCall) {
    if (perCall <= Duration.zero) {
      throw ArgumentError.value(
        perCall,
        'perCall',
        'a per-call timeout is a positive duration. engine.md §3.2 refuses zero or less at '
            'construction rather than yielding a deadline that has already expired',
      );
    }
    // Clamped rather than tested: an exhausted parent is *zero* left, and 1µs is the least that
    // is not the zero §3.2 refuses. `min(perCall, …)` then applies exactly as below, so a
    // per-call timeout smaller than a microsecond — which no Duration can be — is unreachable and
    // needs no second branch.
    final left = remaining;
    final available = left == Duration.zero
        ? const Duration(microseconds: 1)
        : left;
    return Deadline(
      clock: _clock,
      startedAt: _clock.now(),
      limit: perCall < available ? perCall : available,
    );
  }

  /// Elapsed time on the monotonic clock, which is the run's own zero by construction.
  Duration get _elapsed => _clock.monotonicNow() - _origin;

  @override
  String toString() =>
      'Deadline(startedAt: ${_startedAt.toIso8601String()}, limit: $_limit)';
}

/// One withheld estimate, and the handle that names it.
///
/// §5.1's shared ledger means a subagent's limit is taken out of the parent's *before* the child
/// starts and given back whatever the child did not spend. That needs a name: with two children
/// in flight, "return a reserve" without saying which one lets a map's iteration order decide how
/// much budget the parent gets back, and a run's ceiling then depends on which child happened to
/// be checked first. So [CostBudget.reserve] hands one of these back and
/// [CostBudget.settleReserve] and [CostBudget.releaseReserve] take it.
///
/// **The constructor is private and [reserveId] is public.** A caller cannot mint a handle, which
/// is the point: a forgeable handle naming another child's reserve would return that child's
/// withheld money to the parent while the live child kept nothing. [reserveId] is public because a
/// trace has to quote it — `child 3 reserved 4000 tokens` — and it is a **counter** rather than a
/// generated id because a value object holds no id source and a replayed run must number its
/// reserves identically twice ([process/testing-strategy.md] §3). It is an `int` and not a
/// [concepts.md] §2 id, so it does not consume the `concepts.md` §2.1 id namespace.
///
/// [process/testing-strategy.md]: ../../../../../docs/process/testing-strategy.md
/// [concepts.md]: ../../../../../docs/concepts.md
final class CostReserve {
  const CostReserve._({
    required this.reserveId,
    required this.tokens,
    required int usdMicros,
  }) : _usdMicros = usdMicros;

  /// This reserve's number within its budget, from 1.
  ///
  /// Unique for the life of the [CostBudget] that issued it and meaningless outside it. It names
  /// a reserve so that [CostBudget.settleReserve] and [CostBudget.releaseReserve] can be about
  /// *this* one; it is not a wire id and never reaches a transcript as one.
  final int reserveId;

  /// The tokens withheld when the reserve was taken.
  final int tokens;

  final int _usdMicros;

  /// The USD withheld, in the same units [CostBudget.spentUsd] reports.
  double get usd => _usdMicros / _microsPerUsd;

  /// The USD withheld, as the exact integer the ledger holds.
  int get usdMicros => _usdMicros;

  @override
  String toString() =>
      'CostReserve(id: $reserveId, tokens: $tokens, usd: $usd)';
}

/// The micro-dollars the USD ledger counts in.
///
/// **One rule for every USD value that enters the ledger: convert by rounding *up*.** An estimate
/// rounded down would let through a call the ceiling refuses; a settle rounded down would make the
/// ledger smaller than the money that was actually spent; and a ceiling rounded down would lower a
/// limit the operator configured. Rounding up is conservative in all three cases, costs at most
/// one millionth of a dollar, and is the only direction that can fail closed.
///
/// The count is exact integer arithmetic, so `0.1 + 0.2` never happens: [CostBudget.spentUsd] is
/// one division per read, and IEEE division is correctly rounded, so the getter returns the double
/// nearest the true value rather than an accumulated error. The ceiling and the estimate convert
/// exactly for any value below 9.0e9 USD, which is the whole range in which a ceiling is a
/// ceiling rather than a typo.
const int _microsPerUsd = 1000000;

/// The run's spend and its two ceilings: a ledger, and never a plan.
///
/// ## A ceiling is not a reservation
///
/// §3.2: [canAfford] answers whether the next *estimated* call fits and [settle] counts usage
/// that has actually been reported. So a turn that costs more than it estimated leaves the ledger
/// over its ceiling, and that is correct: **the ledger records what happened rather than what was
/// hoped for.** A budget that clamped at its ceiling would report a spend that never happened,
/// and every figure derived from it — an operator's invoice estimate, a transcript's cost line —
/// would be wrong in the direction that looks cheaper.
///
/// ## Two ceilings, not one derived from the other
///
/// §3.2: "Tokens and USD are both ceilings and either one can end the run." A run with a generous
/// USD ceiling and a tight token ceiling stops on tokens, so the token figure is a limit in its
/// own right and is never computed from a price per token. Prices move between models and
/// between providers; a token ceiling computed from yesterday's price is a different limit
/// tomorrow.
///
/// ## There is no way to raise a ceiling
///
/// §3: "Model, tool and subagent cannot bypass `CostBudget`, deadline, cancellation or policy
/// through an internal API." [maxTokens] and [maxUsd] are `final`, the only constructors are the
/// factory that validates them and the private one, and there is no `withCeiling`, no `raise` and
/// no setter. That is the whole design: the absence of the method *is* the invariant, so a tool
/// cannot widen its own limit because there is nothing to call.
final class CostBudget {
  /// Creates a ledger with the given ceilings.
  ///
  /// Throws [ArgumentError] when both are null: §3 makes a budget with no ceiling a
  /// configuration error raised before any model turn, and §5.1 says "a missing limit is a
  /// configuration error, not infinity". A budget that answers `canAfford` with a shrug is the
  /// one thing this type must not be.
  ///
  /// Throws [ArgumentError] naming the parameter for a negative [maxTokens], and for a [maxUsd]
  /// that is negative, `double.nan` or `double.infinity`. NaN is refused by name because every
  /// comparison against it is false — `nan < 0.0` and `nan > 1.0` are both false — so the range
  /// check written as two comparisons would admit one silently and make the ceiling unreachable;
  /// an infinity is §3's forbidden "no limit" spelled with a number.
  factory CostBudget({int? maxTokens, double? maxUsd}) {
    if (maxTokens == null && maxUsd == null) {
      throw ArgumentError(
        'a CostBudget needs at least one ceiling. engine.md §3 makes the budget mandatory and '
        '§5.1 says a missing limit is a configuration error, not infinity',
      );
    }
    if (maxTokens != null && maxTokens < 0) {
      throw ArgumentError.value(
        maxTokens,
        'maxTokens',
        'a token ceiling is not negative',
      );
    }
    if (maxUsd != null) {
      _checkUsd(maxUsd, 'maxUsd');
    }
    return CostBudget._(
      maxTokens: maxTokens,
      maxUsdMicros: maxUsd == null ? null : _toMicros(maxUsd),
    );
  }

  CostBudget._({required int? maxTokens, required int? maxUsdMicros})
    : _maxTokens = maxTokens,
      _maxUsdMicros = maxUsdMicros;

  final int? _maxTokens;
  final int? _maxUsdMicros;

  AlteriOneUsage _usage = const AlteriOneUsage();
  int _spentUsdMicros = 0;
  int _nextReserveId = 1;
  final Map<int, CostReserve> _reserves = <int, CostReserve>{};

  /// The tokens spent so far, the sum of every settled [AlteriOneUsage.totalTokens].
  ///
  /// [AlteriOneUsage.totalTokens] rather than a count of this file's own: it is derived by the
  /// type that owns the four counts, so it cannot disagree with them.
  int get spentTokens => _usage.totalTokens;

  /// The USD spent so far, as the exact integer the ledger holds.
  int get spentUsdMicros => _spentUsdMicros;

  /// The USD spent so far. One division from [spentUsdMicros]; see [_microsPerUsd].
  double get spentUsd => _spentUsdMicros / _microsPerUsd;

  /// The token ceiling, or null when only [maxUsd] was given.
  int? get maxTokens => _maxTokens;

  /// The USD ceiling, or null when only [maxTokens] was given.
  double? get maxUsd =>
      _maxUsdMicros == null ? null : _maxUsdMicros / _microsPerUsd;

  /// Whether either ceiling has been reached.
  ///
  /// `>=`, so reaching a ceiling exactly *is* exhaustion. Reserves count: a budget with a child's
  /// reserve outstanding reports exhausted while the child runs, which is the honest answer —
  /// the money is committed, whether or not it has been spent yet.
  bool get isExhausted =>
      (_maxTokens != null && _usage.totalTokens >= _maxTokens) ||
      (_maxUsdMicros != null && _spentUsdMicros >= _maxUsdMicros);

  /// How many reserves are outstanding.
  ///
  /// §5.1: one budget belongs to the whole tree, so this is the number of children currently
  /// holding their parent's money. It is the figure a run's teardown needs, and it is the one
  /// that proves a dead child's reserve was returned.
  int get outstandingReserves => _reserves.length;

  /// Whether the estimate of [tokens] and [usd] fits in what is left.
  ///
  /// The check §4's "aggregated before the next step" makes *before* the call, and it is an
  /// estimate: it answers whether a call may start, not what it will cost. Throws
  /// [ArgumentError] for a negative [tokens] or a [usd] that is negative, NaN or infinite —
  /// a caller reporting negative usage has a bug, and a negative estimate would read as "always
  /// fits".
  ///
  /// A total landing exactly on a ceiling **fits**: the call is allowed to spend the last of the
  /// budget, and the budget is exhausted afterwards. Refusing on `>=` would make a ceiling mean
  /// "slightly less than this".
  bool canAfford({required int tokens, required double usd}) {
    _checkTokens(tokens, 'tokens');
    _checkUsd(usd, 'usd');
    if (_maxTokens != null && _usage.totalTokens + tokens > _maxTokens)
      return false;
    if (_maxUsdMicros != null &&
        _spentUsdMicros + _toMicros(usd) > _maxUsdMicros) {
      return false;
    }
    return true;
  }

  /// Records what one call actually cost.
  ///
  /// §3.2: "An estimate is checked before the call and the real usage settles after it", so this
  /// is the only place [AlteriOneUsage] enters the ledger and [AlteriOneUsage.operator +] is how
  /// a run accumulates. Settling **more** than was estimated is normal and is not refused; the
  /// ledger goes over its ceiling and stays there, which is the point of the previous paragraph.
  ///
  /// Throws [ArgumentError] for a negative [usd], or for a NaN or an infinity: usage is what the
  /// endpoint reported and none of those is a thing an endpoint reports. [AlteriOneUsage] cannot
  /// carry one, its counts being `int`.
  void settle(AlteriOneUsage usage, {required double usd}) {
    _checkUsd(usd, 'usd');
    _add(usage, _toMicros(usd));
  }

  /// Withholds [tokens] and [usd] for a child, and returns the handle that names it.
  ///
  /// §5.1: "The parent reserves the child's limit and all descendant usage settles into the
  /// shared ledger; creating a subagent creates no new budget." Withholding is what makes that
  /// true — the estimate joins the ledger straight away, so two children cannot both be handed
  /// the last of the parent's budget, and a reserve **never mints**: the ceiling is untouched and
  /// the parent's remaining is what shrinks.
  ///
  /// Throws [StateError] when [canAfford] is false, which is a refusal rather than a null
  /// because it is the *state* that answers, not the arguments: §2 checks the budget before it
  /// starts a child and reports `-32032`, and a `CostBudget` that returned "nothing" would give
  /// its caller a second way to skip that check and no way to tell the two apart from an
  /// allocation failure.
  ///
  /// The alternative rejected is §2's `canReserve(...)` followed by a separate reserve: a check
  /// and an action a tool could interleave with, and §3's "cannot bypass `CostBudget` … through
  /// an internal API" is easier to hold when the action refuses for itself.
  CostReserve reserve({required int tokens, required double usd}) {
    if (!canAfford(tokens: tokens, usd: usd)) {
      throw StateError(
        'a reserve of $tokens tokens and $usd USD does not fit: spent ${_usage.totalTokens} of '
        '${_maxTokens ?? '-'} tokens and ${_spentUsdMicros / _microsPerUsd} of '
        '${maxUsd ?? '-'} USD. engine.md §5.1 makes the child cost come out of the '
        "parent's remaining, so a reserve that did not fit is -32032 for the run",
      );
    }
    final reserve = CostReserve._(
      reserveId: _nextReserveId++,
      tokens: tokens,
      usdMicros: _toMicros(usd),
    );
    _reserves[reserve.reserveId] = reserve;
    // The estimate enters `_usage` as spending rather than as a separate "committed" column, so
    // `spentTokens` and `isExhausted` see it — see [isExhausted] for why that is the honest
    // answer. The alternative is a ledger that understates itself while a child is in flight: the
    // report an operator reads at -32032 has to mean "this much is committed", and the estimate
    // is the only figure available before the child reports anything. Settling replaces it with
    // the real usage, so the overstatement lasts exactly as long as the child does.
    _add(AlteriOneUsage(inputTokens: tokens), reserve.usdMicros);
    return reserve;
  }

  /// Settles [reserve] against what the child actually did, and returns the unused part.
  ///
  /// The withheld estimate comes off the ledger first and the real usage goes on, so a child that
  /// spent less than its estimate hands the difference back to the parent without a separate call
  /// and a child that spent more leaves the ledger over the ceiling — §3.2's rule, applied to a
  /// reserve instead of to a turn. One call, both halves: a caller that had to remember to
  /// release afterwards would leak an estimate for every child that finished, which is §5.1's
  /// "the parent's budget would drift downwards for a run that spent nothing".
  ///
  /// Throws [StateError] when [reserve] is not outstanding — one already settled, one already
  /// released, or one from another budget. Settling twice would take the estimate off the ledger
  /// twice and hand back money nobody spent, so this is refused rather than ignored.
  void settleReserve(
    CostReserve reserve,
    AlteriOneUsage usage, {
    required double usd,
  }) {
    // Validated before anything is taken out of the ledger, so a rejected argument leaves the
    // reserve outstanding and the caller can settle it properly instead of finding a ledger that
    // has already given the estimate back.
    _checkUsd(usd, 'usd');
    final withheld = _take(reserve, 'settled');
    _release(withheld);
    _add(usage, _toMicros(usd));
  }

  /// Returns [reserve]'s withheld estimate to the ledger, and says whether it did.
  ///
  /// §5.1: "a reserve that is never settled — because the child died — is returned, or the
  /// parent's budget would drift downwards for a run that spent nothing." False means there was
  /// nothing to return: already settled, already released, or not from this budget. False rather
  /// than a throw because returning is what a teardown does on every path, including the ones
  /// where the child was cancelled before it ever started.
  bool releaseReserve(CostReserve reserve) {
    final withheld = _outstanding(reserve);
    if (withheld == null) return false;
    _reserves.remove(reserve.reserveId);
    _release(withheld);
    return true;
  }

  /// This budget's live entry for [reserve], or null when it has none.
  ///
  /// **Identity, not just the id.** [CostReserve.reserveId] is a counter local to one budget, so
  /// *every* budget's first reserve is id 1 and a lookup keyed on it alone accepts a handle from
  /// another budget whenever the ids happen to line up — which, for the first reserve of each, is
  /// always. Two runs in one process would then refund or settle each other's live children, and a
  /// tool that stashed a handle across a boundary could move money that was never its own. The
  /// private constructor stops a handle being *minted*; this stops one being *borrowed*, which is
  /// the half a caller actually controls.
  CostReserve? _outstanding(CostReserve reserve) {
    final held = _reserves[reserve.reserveId];
    return held != null && identical(held, reserve) ? held : null;
  }

  /// The live entry for [reserve], or a [StateError] naming what went wrong.
  CostReserve _take(CostReserve reserve, String action) {
    final withheld = _outstanding(reserve);
    if (withheld == null) {
      throw StateError(
        'reserve ${reserve.reserveId} is not outstanding and cannot be $action. A reserve is '
        'outstanding until it is settled or released once, and this budget does not know '
        'this one — a reserve from another budget would settle a child against a ledger that '
        'never paid for it',
      );
    }
    _reserves.remove(reserve.reserveId);
    return withheld;
  }

  /// Takes [withheld]'s estimate back off the ledger.
  ///
  /// [inputTokens] is the field it comes off, and that is symmetric rather than arbitrary:
  /// [reserve] put the estimate there as [AlteriOneUsage.inputTokens] and nowhere else, so a
  /// release undoes exactly the addition that made it. The two count fields are restated rather
  /// than touched, and `AlteriOneUsage` is immutable by construction, which is why this is a new
  /// value and not a subtraction on the old one.
  void _release(CostReserve withheld) {
    _usage = AlteriOneUsage(
      inputTokens: _usage.inputTokens - withheld.tokens,
      outputTokens: _usage.outputTokens,
      cachedInputTokens: _usage.cachedInputTokens,
    );
    _spentUsdMicros -= withheld.usdMicros;
  }

  /// Adds one call's real usage to the ledger.
  ///
  /// Through [AlteriOneUsage.operator +] rather than by hand: that is what §4's "aggregated into
  /// `CostBudget` before the next step" is for, and it sums `cachedInputTokens` correctly — a
  /// hand-rolled accumulator gets it wrong within a few lines and the symptom is a cost that is
  /// quietly too low.
  void _add(AlteriOneUsage usage, int usdMicros) {
    _usage = _usage + usage;
    _spentUsdMicros += usdMicros;
  }

  @override
  String toString() =>
      'CostBudget(spentTokens: ${_usage.totalTokens}, maxTokens: ${_maxTokens ?? '-'}, '
      'spentUsd: $spentUsd, maxUsd: ${maxUsd ?? '-'}, reserves: ${_reserves.length})';
}

/// How many model turns a run may take, counted once each.
///
/// §3.1: "One **step** | One model turn, counted once regardless of how many tool calls it
/// requested." The distinction is the whole reason this is a class rather than a counter the loop
/// increments wherever it finds convenient: a turn that asks for eight tool calls is **one** step,
/// and a loop that counted the tool calls would end a run eight times too early while reporting
/// a progress story the specification does not tell.
///
/// It knows nothing about the deadline, the budget or the token. §3.2: "The step limit and the
/// stagnation detector are separate, and neither subsumes the other" — a step limit bounds a run
/// that is making progress slowly, and the two ceilings bound a run that is being cut off. There
/// is no member here that consults another primitive, so a caller cannot combine them into one
/// number and lose which of the three actually ended the run.
final class StepBudget {
  /// Creates a budget of [maxSteps] model turns.
  ///
  /// Throws [ArgumentError] naming `maxSteps` when it is zero or negative. §5.1's "a missing
  /// limit is a configuration error, not infinity" is the rule for a missing limit, and a zero is
  /// the limit that would let the run start one turn and then stop: a budget of zero is a
  /// configuration that happens to be typed rather than one the type refuses.
  factory StepBudget({required int maxSteps}) {
    if (maxSteps <= 0) {
      throw ArgumentError.value(
        maxSteps,
        'maxSteps',
        'a step limit is a positive count of model turns. engine.md §5.1 says a missing limit '
            'is a configuration error, not infinity, and zero is not a limit',
      );
    }
    return StepBudget._(maxSteps: maxSteps);
  }

  StepBudget._({required this.maxSteps});

  /// The ceiling this budget was created with. `final`, for §3's reason: no method raises it.
  final int maxSteps;

  int _steps = 0;

  /// How many model turns have been taken. Never above [maxSteps].
  int get steps => _steps;

  /// Whether the run has taken every turn it is allowed.
  bool get isExhausted => _steps >= maxSteps;

  /// Takes one step, and says whether there was one left.
  ///
  /// The form §2's loop wants at a boundary, where "no" and "stop the run" are the same decision.
  /// It never increments past [maxSteps], so [steps] is the truth about how far the run got and a
  /// caller cannot make the two disagree by asking twice.
  bool tryStep() {
    if (isExhausted) return false;
    _steps++;
    return true;
  }

  /// Takes one step and returns the new count.
  ///
  /// For a caller that increments as it goes — `final step = budget.nextStep();` — where the
  /// number itself is what goes into `step_started`. Throws [StateError] when the budget is
  /// exhausted, because the alternative is a counter that goes past its ceiling and a caller that
  /// only discovers it in the transcript.
  int nextStep() {
    if (!tryStep()) {
      throw StateError(
        'the step limit of $maxSteps is reached. engine.md §2 stops the run here, and a step '
        'that goes past its own ceiling is a counter nobody can reconcile with the '
        'transcript',
      );
    }
    return _steps;
  }

  @override
  String toString() => 'StepBudget(steps: $_steps, maxSteps: $maxSteps)';
}

/// The §3.1 stagnation detector: the same tool with canonically identical arguments, over and
/// over.
///
/// ## The signature
///
/// §3.1 fixes it as `SHA-256(toolId ‖ canonicalArgsJson)`, and this class computes exactly that
/// — see the library documentation for why SHA-256 is implemented privately here rather than
/// taken from a package. The concatenation carries **no separator**, which is §3.1's spelling and
/// is safe for a specific reason: `canonicalArgsJson` is a JSON object and therefore starts with
/// `{`, and the tool-id grammar ([toolIdGrammar]) admits no `{`, so no pair of (tool id, arguments)
/// can produce the same byte string as a different pair.
///
/// ## Canonical arguments arrive already canonical
///
/// §3.1 defines canonical args as "keys sorted lexicographically, no insignificant whitespace,
/// paths normalised to project-relative POSIX form, numbers in the fixed canonical form". That
/// normalisation is **not** reimplemented here. It is the caller's to have done — the manifest and
/// argument normalisation of task `0.29` is the half that produces it, and the tool boundary is
/// where it belongs — and this type takes the finished text as an argument so that the definition
/// has exactly one implementation. A detector that re-sorted keys would be a second definition,
/// and the two would disagree about one of the rules and neither would turn red.
///
/// ## A successful outcome does not reset the window
///
/// §3.1: "A different signature, a different tool, or a terminal outcome resets the window. A
/// successful `ToolOutcome.ok` does **not** reset it — the loop, not the outcome, is the signal."
/// That rule is the shape of this class rather than a rule inside it: **there is no member that
/// takes a tool outcome**, so there is no call to forget. [record] is the only way a signature
/// enters, [reset] is the loop's for a terminal outcome, and a different signature or tool
/// resets the window by pushing [isStagnant] to false on its own. A loop that reset on success
/// would have to reach for a member that does not exist.
///
/// ## At least 3
///
/// §3.1: "a legitimate retry of a transient failure with identical arguments does trip the
/// detector, which is why `stagnationWindow` should be at least 3". A window of 1 would end a run
/// on a single call and of 2 on a single retry, so the factory refuses both, citing the section's
/// own advice rather than a number invented here.
///
/// [toolIdGrammar]: ../core/namespace.dart
final class StagnationDetector {
  /// Creates a detector whose window is [window] model turns.
  ///
  /// Throws [ArgumentError] naming `window` when it is below 3 — see the class documentation and
  /// §3.1's "stagnationWindow should be at least 3".
  factory StagnationDetector({required int window}) {
    if (window < 3) {
      throw ArgumentError.value(
        window,
        'window',
        'engine.md §3.1 says stagnationWindow should be at least 3: a legitimate retry of a '
            'transient failure has identical arguments and does trip the detector, so a window '
            'of 1 ends a run on one call and a window of 2 on one retry',
      );
    }
    return StagnationDetector._(window: window);
  }

  StagnationDetector._({required this.window})
    : _signatures = <String>[],
      _lastSignature = null;

  /// How many of the last model turns the window covers. `final`: §3.2 gives the detector and the
  /// step limit no way to widen each other, and a window that grew as a run went on would not be
  /// the configured one.
  final int window;

  final List<String> _signatures;
  String? _lastSignature;

  /// The §3.1 signature of [toolId] called with [canonicalArgsJson], as lowercase hex.
  ///
  /// **Public, and that is deliberate**, for the reason `identityBlock` is: it is part of the
  /// detector's algorithm rather than an internal detail, so a contract test can pin it against
  /// the published SHA-256 vectors and a caller writing a replay harness elsewhere can reproduce
  /// a signature instead of comparing opaque strings.
  static String signatureOf(String toolId, String canonicalArgsJson) =>
      _sha256Hex(<int>[
        ...utf8.encode(toolId),
        ...utf8.encode(canonicalArgsJson),
      ]);

  /// Pushes this call's signature into the window, and reports whether the run is stagnant.
  ///
  /// Returns [isStagnant] **after** the push, so a caller does not have to record and then ask.
  /// The window holds the last [window] signatures and nothing more; a different signature
  /// therefore resets it by being different, with no clearing step (§3.1's reset rule, read as a
  /// ring rather than a flag).
  ///
  /// One call is one **model turn**'s contribution: §3.1's window is "the same signature appearing
  /// in `stagnationWindow` of the last `stagnationWindow` model turns", so a caller records once
  /// per turn — a turn that made four identical calls pushes one signature, and a turn that made
  /// none pushes none.
  ///
  /// Throws [ArgumentError] naming `toolId` when it is empty: a signature over no tool separates
  /// nothing, and an empty id reaching here means the caller has not resolved the tool, which is
  /// a bug worth reporting at the boundary rather than a run that stagnates for the wrong reason.
  /// [canonicalArgsJson] is a `String` and not a parsed value, so nothing else about it can fail
  /// here — it is not this class's job to decide whether the text is canonical.
  bool record(String toolId, String canonicalArgsJson) {
    if (toolId.isEmpty) {
      throw ArgumentError.value(
        toolId,
        'toolId',
        'a stagnation signature is SHA-256(toolId + canonicalArgsJson). engine.md §3.1 names a '
            'tool and an argument document, and an empty tool id is neither',
      );
    }
    final signature = signatureOf(toolId, canonicalArgsJson);
    _signatures.add(signature);
    if (_signatures.length > window) {
      _signatures.removeAt(0);
    }
    _lastSignature = signature;
    return isStagnant;
  }

  /// Empties the window.
  ///
  /// §3.1's other reset: a **terminal outcome**. The loop calls this when the run ends, so a
  /// detector reused for the next run does not inherit the last one's window, and nothing else
  /// calls it — the "a successful `ToolOutcome.ok` does not reset it" half of the rule is not
  /// here because there is no member that could express it.
  ///
  /// [lastSignature] is deliberately left as it was: the caller quotes it in the event that ends
  /// the run, and clearing it would erase the evidence at the moment it is written down.
  void reset() => _signatures.clear();

  /// Whether the window is full and every signature in it is the same.
  ///
  /// False until [window] turns have been recorded, whatever they were — a detector that reported
  /// stagnation on a partially filled window would trip on the first turn.
  bool get isStagnant {
    if (_signatures.length < window) return false;
    final first = _signatures.first;
    return _signatures.every((signature) => signature == first);
  }

  /// How many signatures the window currently holds, from 0 to [window].
  ///
  /// Not the same question as [isStagnant], and a caller that wants to render a progress line
  /// wants this: a window of 3 holding 3 equal signatures is stagnant, and a window of 3 holding
  /// 3 is also what it holds on the turn before the detector says so.
  int get recorded => _signatures.length;

  /// The signature of the most recent [record], or null before the first one.
  ///
  /// §2 finishes a stagnant run with `Stagnant(signature: state.lastSignature)`, and this is that
  /// value: the hex a transcript and an operator's log quote, so the run's last repeated call can
  /// be reproduced from the record.
  String? get lastSignature => _lastSignature;

  @override
  String toString() =>
      'StagnationDetector(window: $window, recorded: $recorded, '
      'stagnant: $isStagnant)';
}

/// The four controls of one run, and the single question a loop asks at every boundary.
///
/// §2 asks it twice — at the top of the loop and again before every tool call — and this is that
/// question with the four answers in one type. Holding them together is what makes the
/// combination testable: a caller cannot hold a deadline from one run and a budget from another
/// and call the result a run's controls.
///
/// ## Precedence is fixed, and it is §2's order
///
/// cancel, then deadline, then budget, then steps. §2 writes exactly this order, twice, in the
/// pseudocode that predates this file; a precedence of this file's own invention would make
/// `task_done` disagree with the specification's own loop.
///
/// The order is also the only one its reasons support:
///
/// - **Cancellation first.** It is the only one of the four that arrives from outside the run — a
///   person interrupting, a peer's `$/cancelRequest` — so it is the answer that must not be
///   masked by a limit the run happened to reach in the same instant. A run that reports a
///   deadline to a person who pressed Ctrl-C teaches them the wrong thing about what happened.
/// - **The deadline before the budget.** A time limit is a property of the run itself and holds
///   whatever the run did with its money, so it is checked where it does not depend on a spend.
/// - **The budget before the step limit.** Both are allowances, and §3.1 makes the step limit a
///   bound on a run that is *progressing*: the run reached the end of its own step allowance
///   rather than being cut off. The step limit is also the only one of the four with no wire code
///   — `EngineDiagnosticCode.engineMaxSteps` is a diagnostic, and
///   [reference/error-codes.md] §1.1 says a new variant of an existing failure mode is a
///   diagnostic and not a number — so it is the least terminal of the four and goes last.
///
/// ## Stagnation is not one of them
///
/// §3.2: "The step limit and the stagnation detector are separate, and neither subsumes the
/// other." [StagnationDetector] is therefore **not** a member here. It answers a different
/// question with a different code — `stagnationDetected` (`-32033`), which `error.dart` marks
/// `feedsToModel` — and folding it into one `isTerminal` with the four controls would make a run
/// that stopped making progress indistinguishable from one that ran out of time.
///
/// [reference/error-codes.md]: ../../../../../docs/reference/error-codes.md
final class RunControls {
  /// Binds the four controls of one run.
  ///
  /// No validation: every member has already refused what §3 refuses, and this constructor only
  /// groups them. A `RunControls` therefore cannot exist without a finite deadline, a budget with
  /// a ceiling, a live-or-cancelled token and a positive step limit — §3's mandatory four, and
  /// §3's "missing or invalid budget is a configuration error raised before any model turn" is
  /// enforced where the budget is built rather than here.
  const RunControls({
    required this.deadline,
    required this.budget,
    required this.cancel,
    required this.steps,
  });

  /// The run's time limit. `final` for §3's reason: no method raises it.
  final Deadline deadline;

  /// The run's shared ledger — one per tree, §5.1.
  final CostBudget budget;

  /// The run's cancellation signal, cascading into every child. `final` for §3's reason.
  final CancelToken cancel;

  /// The run's model-turn limit. `final` for §3's reason.
  final StepBudget steps;

  /// Whether the run must end now.
  bool get isTerminal => stopReason != null;

  /// The first reason this run must end, or null when it may take another step.
  ///
  /// §2's boundary check, in §2's order — see the class documentation for why that order. The
  /// four are read from their own primitives and nothing here combines them into one number, so
  /// `task_done` can always say *which* control ended the run rather than that "a limit" did.
  ///
  /// Cancellation is read as [CancelToken.reason] rather than as [CancelToken.isCancelled]
  /// followed by an assertion that the reason is there: the protocol package states the two are
  /// one state ("null exactly when [CancelToken.isCancelled] is false"), so reading the cause is
  /// the same fact with the value in hand, and there is nothing to assert.
  RunStopReason? get stopReason {
    final reason = cancel.reason;
    if (reason != null) return Cancelled(reason);
    if (deadline.isExpired) return DeadlineExceeded(deadline.remaining);
    if (budget.isExhausted) {
      return BudgetExhausted(budget.spentTokens, budget.spentUsd);
    }
    if (steps.isExhausted) return StepLimitReached(steps.steps);
    return null;
  }

  @override
  String toString() =>
      'RunControls(deadline: $deadline, budget: $budget, steps: $steps, '
      'cancelled: ${cancel.isCancelled})';
}

/// Why a run ended, or was refused another step: a closed union over the four controls.
///
/// `sealed`, so a `switch` over it is exhaustive and a fifth control breaks compilation in every
/// consumer rather than arriving as an unhandled case. `sealed class` and not `sealed interface`
/// because the pinned SDK does not parse the latter — the same arrangement as `SpanParent` in
/// `core/event.dart`.
///
/// ## A terminal control outcome is not a `ToolOutcome`
///
/// §3.2, last bullet: "`-32030`/`-32031`/`-32032` end the run; a tool failure is something the
/// model sees and can correct. Anything that lets a tool return a budget or deadline exhaustion
/// as an ordinary outcome has turned a terminal control decision into a suggestion." Nothing in
/// this hierarchy takes a tool's result, a message or a diagnostic, and no constructor of any
/// variant is reachable from a tool boundary — so the suggestion cannot be built here in the
/// first place. It is a type, not a convention the loop upholds.
sealed class RunStopReason {
  const RunStopReason();

  /// The wire code for this stop, or null when the taxonomy has none for it.
  ///
  /// Null for [StepLimitReached] alone: §3.2 names `-32030`/`-32031`/`-32032` and
  /// [reference/error-codes.md] §1 has no step-limit number, because the step limit is not a
  /// cut-off — `EngineDiagnosticCode.engineMaxSteps` says "separate from a budget on purpose: it
  /// is not a spend". Inventing a fourth number would be inventing a wire promise, and §1.1 says
  /// the way to add a variant of an existing failure mode is a diagnostic in §3, not a number.
  ///
  /// The enum rather than a bare `int`, so a caller writes the name at the call site and
  /// [DomainErrorCode.code] stays the only place the digits live.
  ///
  /// [reference/error-codes.md]: ../../../../../docs/reference/error-codes.md
  DomainErrorCode? get wireCode;
}

/// The run was cancelled. §3.2's `-32031`.
final class Cancelled extends RunStopReason {
  /// Creates a cancelled stop for [reason].
  const Cancelled(this.reason);

  /// Why it was cancelled, as the protocol package's token recorded it.
  ///
  /// Never null and never a value this file chose: [CancelToken] keeps the **first** reason and
  /// derives it into every child, so this is the one cause the whole tree saw. A run that was
  /// cancelled for `user_interrupt` cannot also report a deadline, whatever the order.
  final CancelReason reason;

  @override
  DomainErrorCode get wireCode => DomainErrorCode.cancelled;

  @override
  String toString() => 'Cancelled($reason)';
}

/// The run's time ran out. §3.2's `-32030`.
final class DeadlineExceeded extends RunStopReason {
  /// Creates a deadline stop with [remaining] left, which is [Duration.zero].
  const DeadlineExceeded(this.remaining);

  /// How much time was left when the run stopped: always [Duration.zero].
  ///
  /// §2's pseudocode finishes a timeout with `Timeout(Duration.zero)`, and [Deadline.remaining]
  /// clamps rather than reporting the overshoot, so this field is zero by construction. It is
  /// carried because the loop puts it in the terminal outcome it hands back, and a
  /// `DeadlineExceeded` with no time in it forces every caller to write `Duration.zero` itself.
  final Duration remaining;

  @override
  DomainErrorCode get wireCode => DomainErrorCode.deadlineExceeded;

  @override
  String toString() => 'DeadlineExceeded($remaining)';
}

/// The run's ledger reached a ceiling. §3.2's `-32032`.
final class BudgetExhausted extends RunStopReason {
  /// Creates a budget stop reporting what had been spent.
  const BudgetExhausted(this.spentTokens, this.spentUsd);

  /// Tokens spent when the run stopped.
  ///
  /// §2's `BudgetExceeded(spent: budget.spent)`. It may be **above** the ceiling, and that is
  /// correct: §3.2 says a turn costing more than it estimated leaves the ledger over its ceiling,
  /// because the ledger records what happened rather than what was hoped for.
  final int spentTokens;

  /// USD spent when the run stopped, over its ceiling for the same reason.
  final double spentUsd;

  @override
  DomainErrorCode get wireCode => DomainErrorCode.budgetExhausted;

  @override
  String toString() =>
      'BudgetExhausted(spentTokens: $spentTokens, spentUsd: $spentUsd)';
}

/// The run took every model turn it was allowed. No wire code; see [RunStopReason.wireCode].
final class StepLimitReached extends RunStopReason {
  /// Creates a step-limit stop at [steps] model turns.
  const StepLimitReached(this.steps);

  /// How many model turns were taken: §3.1's one step is one turn, counted once.
  final int steps;

  @override
  DomainErrorCode? get wireCode => null;

  @override
  String toString() => 'StepLimitReached($steps)';
}

/// Refuses a negative token count, which is never a real count.
void _checkTokens(int tokens, String name) {
  if (tokens < 0) {
    throw ArgumentError.value(
      tokens,
      name,
      'a token count is not negative. The ledger reports what was spent, and a negative entry '
      'would hand budget back that was never there',
    );
  }
}

/// Refuses a USD value that is not a finite non-negative amount.
///
/// NaN and infinity by name, for the reason [CostBudget]'s constructor gives: every comparison
/// against NaN is false, so a check written as two comparisons admits it silently and the ceiling
/// becomes unreachable; an infinity is §3's forbidden "no limit" spelled with a number.
void _checkUsd(double usd, String name) {
  if (usd.isNaN || usd.isInfinite || usd < 0) {
    throw ArgumentError.value(
      usd,
      name,
      'an amount of US dollars is a finite, non-negative number',
    );
  }
}

/// Converts [usd] to micro-dollars, rounding **up** — see [_microsPerUsd] for the rule and why
/// it is that way rather than nearest.
int _toMicros(double usd) => (usd * _microsPerUsd).ceil();

/// SHA-256 of [message], as lowercase hex — FIPS 180-4 §6.2.
///
/// **Not** `package:crypto`, and not a different hash either. §3.1 names SHA-256 for the
/// stagnation signature, so a cheaper digest here would be a second, silent change to what the
/// signature *is*, and a hash nobody can check against a published vector is the failure
/// `identityBlock` documents when it was missing its final inversion: still deterministic, still
/// wrong, and nothing turns red.
///
/// Pure Dart, with every intermediate masked to 32 bits — including the complement, written as an
/// exclusive-or with all ones rather than `~` so a web build's arithmetic is never asked about a
/// value above 2⁵³. That is the same argument `identityBlock` makes for CRC-32 over FNV-1a: a
/// signature that differed between the VM and a browser would be a digest that matched on one
/// platform and not the other, visible only as a replay that failed in a web build.
///
/// The input is a tool id and one JSON document, both short, so the 64-bit length field is
/// written from an `int` that is exact well past any length this is called with.
String _sha256Hex(List<int> message) {
  final digest = _sha256(message);
  final hex = StringBuffer();
  for (final word in digest) {
    hex.write(word.toRadixString(16).padLeft(8, '0'));
  }
  return hex.toString();
}

/// The eight working words and the eight state words.
List<int> _sha256(List<int> message) {
  // One 0x80 byte, then zeros until the length leaves room for the 64-bit bit count — the
  // padding rule of FIPS 180-4 §5.1.1, written as the block count rather than as a search for
  // the zero position, because `((length + 9 + 63) ~/ 64) * 64` is the only one of the two that
  // cannot be off by one at the boundary length of 56.
  final blockCount = (message.length + 9 + 63) ~/ 64;
  final padded = List<int>.filled(blockCount * 64, 0);
  padded.setRange(0, message.length, message);
  padded[message.length] = 0x80;
  final bitLength = message.length * 8;
  final lengthOffset = padded.length - 8;
  padded[lengthOffset] = (bitLength >> 56) & 0xFF;
  padded[lengthOffset + 1] = (bitLength >> 48) & 0xFF;
  padded[lengthOffset + 2] = (bitLength >> 40) & 0xFF;
  padded[lengthOffset + 3] = (bitLength >> 32) & 0xFF;
  padded[lengthOffset + 4] = (bitLength >> 24) & 0xFF;
  padded[lengthOffset + 5] = (bitLength >> 16) & 0xFF;
  padded[lengthOffset + 6] = (bitLength >> 8) & 0xFF;
  padded[lengthOffset + 7] = bitLength & 0xFF;

  final state = List<int>.of(_sha256Initial);
  final schedule = List<int>.filled(64, 0);
  for (var offset = 0; offset < padded.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      schedule[i] =
          (padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final previous = schedule[i - 15];
      final recent = schedule[i - 2];
      final s0 = _rotr32(previous, 7) ^ _rotr32(previous, 18) ^ (previous >> 3);
      final s1 = _rotr32(recent, 17) ^ _rotr32(recent, 19) ^ (recent >> 10);
      schedule[i] = (schedule[i - 16] + s0 + schedule[i - 7] + s1) & _wordMask;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (var i = 0; i < 64; i++) {
      final bigS1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final choose = (e & f) ^ ((e ^ _wordMask) & g);
      final temp1 =
          (h + bigS1 + choose + _sha256RoundConstants[i] + schedule[i]) &
          _wordMask;
      final bigS0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (bigS0 + majority) & _wordMask;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _wordMask;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _wordMask;
    }

    state[0] = (state[0] + a) & _wordMask;
    state[1] = (state[1] + b) & _wordMask;
    state[2] = (state[2] + c) & _wordMask;
    state[3] = (state[3] + d) & _wordMask;
    state[4] = (state[4] + e) & _wordMask;
    state[5] = (state[5] + f) & _wordMask;
    state[6] = (state[6] + g) & _wordMask;
    state[7] = (state[7] + h) & _wordMask;
  }
  return state;
}

/// Rotates a 32-bit word right by [places], masked so nothing widens.
int _rotr32(int word, int places) =>
    ((word >>> places) | (word << (32 - places))) & _wordMask;

/// 32 bits: `0xFFFFFFFF`.
const int _wordMask = 0xFFFFFFFF;

/// SHA-256's initial state — FIPS 180-4 §5.3.3, the first thirty-two bits of the fractional
/// parts of the square roots of the first eight primes.
const List<int> _sha256Initial = <int>[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// SHA-256's round constants — FIPS 180-4 §4.2.2, the first thirty-two bits of the fractional
/// parts of the cube roots of the first sixty-four primes.
///
/// **Written out and not computed.** `identityBlock` builds its 256-entry CRC table by
/// construction, because the shift-and-xor step makes construction the same code as the step.
/// Here it cannot: these are cube roots of primes, and Dart has no arbitrary-precision integer
/// and no `powi`, so a computed table would need a second algorithm to verify against — and a
/// 64-entry literal is 64 opportunities to transcribe a digit wrongly. Which is exactly why
/// `StagnationDetector.signatureOf` is public: a contract test pins it against the published
/// vectors, so a mistyped constant is caught by an outside authority rather than by a second copy
/// of the same mistake.
const List<int> _sha256RoundConstants = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
