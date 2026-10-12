// The contract of the four control primitives a run is bound by. Task 0.14.
//
// What this file is: the mechanical half of "`Deadline` propagates downward as
// `min(perCall, remaining)`, `CancelToken` has a cascade path, `CostBudget` counts tokens and
// USD, and `maxSteps` and the stagnation detector are separate" —
// [docs/process/task-breakdown.md] §`0.14`. The rules it asserts are written down in
// [docs/architecture/engine.md] §3 (the loop invariants), §3.1 (the exact counter and detector
// semantics, which is a table and is parsed below), §3.2 (what each primitive *is*), §5.1 (the
// tree invariants: one shared ledger, `min(configured child deadline, parent remaining)`, a
// derived cancel token), [docs/reference/error-codes.md] §1 and §1.1 (why a step limit is a
// diagnostic and not a number), and [docs/reference/config-schema.md] §2 (the `budgets` block and
// its caps).
//
// The greppable acceptance string for the task is the description of the first test below:
// "nested calls never outlive parent deadline or budget".
//
// ## What this file asserts that a "no errors" check would not
//
// Every limit is checked **at its boundary**, because "the limit is enforced" and "the limit is
// enforced at exactly the limit" are different claims and the second is the one that decides
// whether a run gets one last turn. §3.2 says a per-call timeout larger than what is left is
// *not* an error; §3.1 says one step is one model turn however many tool calls it requested;
// §3.2 says a turn that costs more than it estimated leaves the ledger **over** its ceiling; and
// §3.1 says a successful `ToolOutcome.ok` does **not** reset the stagnation window. Each of those
// four is a case where the convenient implementation and the specified one disagree, and each is
// asserted in the direction the specification names rather than the direction that is easy.
//
// ## Precedence is a contract, not an implementation detail
//
// §2 checks its four controls in a fixed order and `task_done` reports the one that fired, so
// which of the four wins when more than one has fired is a claim a transcript can be wrong about.
// The whole 16-case truth table is asserted, because a precedence demonstrated on two
// simultaneous stops says nothing about the other fourteen orderings.
//
// ## `dart:io` is here, and it is legitimate
//
// Three checks read a file: §3.1's table, `engine.md` §5.1's tree rule, and the source of
// `control.dart` itself. The package itself imports no `dart:io` — `overview.md` §3 — and a test
// is the right place for it, for the reason `configuration.md` §7.4 asks for explicitly. The
// working directory is walked up from, because the acceptance command runs through `melos exec`
// and therefore *in the package*, where a relative path only works when a human runs it by hand
// from the root.
//
// ## No real time, and no network, and no process
//
// Everything time-based goes through `FakeClock`, which advances on demand and never waits. A
// test in this package that called `DateTime.now` or awaited a real delay would be in the
// blocking chain on three operating systems, where a `Timer` fires late and `DateTime.now` is not
// an oracle. `FakeClock.delay` answers immediately **and** moves the clock, so even a hypothetical
// delay here would be free; nothing in this file uses it.
//
// ## Two shapes this file uses on purpose
//
// - **A list of records, never a map keyed by a value that repeats.** Several cases below are
//   variations on one label (four stops tripped, or not), and a map literal keyed by that label
//   would silently keep only the last entry — which is how five assertions go missing without a
//   line of the test ever changing.
// - **A `switch` with no `default`** where the claim is that a union is closed. The sealed
//   hierarchy of `RunStopReason` is provable only by writing the exhaustive switch, and a fifth
//   variant then breaks compilation rather than falling through a `default` nobody reads.
//
// [docs/architecture/engine.md]: ../../../../docs/architecture/engine.md
// [docs/architecture/overview.md]: ../../../../docs/architecture/overview.md
// [docs/reference/error-codes.md]: ../../../../docs/reference/error-codes.md
// [docs/reference/config-schema.md]: ../../../../docs/reference/config-schema.md
// [docs/process/task-breakdown.md]: ../../../../docs/process/task-breakdown.md

import 'dart:convert';
import 'dart:io';

// Through the package's own `src/`, and **not** through the public barrel.
//
// This file recorded a different reason when the barrel's `show` list omitted
// `StagnationDetector`, leaving one of the four primitives with no public name and §3.2's "a
// separate control" not constructible from outside the package. That was a defect in
// `lib/alteri_one_core.dart`; it is fixed, and this comment is the receipt.
//
// The import stays on `src/` for the reason the reference contract test states for its own file:
// a rename or a move inside `lib/` should break this test rather than quietly make it assert a
// property of internals. The barrel is exercised in its own right — see the group at the bottom of
// this file — the members this file pins are the ones `alteri_one_core.dart` must re-export, and a
// name missing from that `show` list is a gap no test importing `src/` can see.
import 'package:alteri_one_core/src/engine/control.dart';

// The token totals the ledger is built from, and the two document barrels: the first because
// `CostBudget` reuses `AlteriOneUsage` rather than inventing a fourth count, the second because
// §3.1's caps are held as profile constants and it is also where `toolIdGrammar` reaches this
// file from, and the third because §1's taxonomy is the protocol package's. A third import of
// `lib/core.dart` is therefore unnecessary — `lib/profile.dart` re-exports `toolIdGrammar` from
// it, and `unnecessary_import` is an INFO, which `--fatal-infos` treats as a failure.
import 'package:alteri_one_core/profile.dart';
import 'package:alteri_one_core/provider.dart';
import 'package:alteri_one_platform/alteri_one_platform.dart';
import 'package:alteri_one_protocol/alteri_one_protocol.dart';

// The public barrel, imported for the one assertion that can only be made through it. Every other
// import above reaches past it deliberately; this one does not, and the two together are what makes
// the header comment true rather than aspirational.
import 'package:alteri_one_core/alteri_one_core.dart' as barrel;
import 'package:test/test.dart';

void main() {
  group('one run and everything nested inside it', () {
    test('nested calls never outlive parent deadline or budget', () {
      // The headline, and the task's greppable acceptance string. The claim is not "a child
      // deadline is smaller than its parent's" — it is that the child's **effective** deadline is
      // `min(what the child asked for, what the parent has left)`, and that a child's budget
      // comes *out of* the parent's remaining rather than being minted beside it.
      //
      // Both halves have a case where the parent has less left than the child asked for, which is
      // the case the wording names and the one a `min` written as "the child's own value" gets
      // wrong: a 30-second model timeout inside a run with 4 seconds remaining is a **4-second**
      // model timeout (§3.2), and §5.1 says the same for a subagent's configured deadline.
      final clock = FakeClock();
      final parent = _controls(
        clock,
        deadline: const Duration(seconds: 10),
        maxTokens: 10000,
      );
      expect(parent.stopReason, isNull, reason: 'nothing has been tripped yet');
      expect(parent.isTerminal, isFalse);

      // Six of the ten seconds spent. Four remain, and the child asks for thirty.
      clock.advance(const Duration(seconds: 6));
      expect(parent.deadline.remaining, const Duration(seconds: 4));
      expect(parent.deadline.isExpired, isFalse);

      final childDeadline = parent.deadline.child(const Duration(seconds: 30));
      expect(
        childDeadline.limit,
        const Duration(seconds: 4),
        reason: '§3.2: a 30s timeout inside a run with 4s left is a 4s timeout',
      );
      expect(
        childDeadline.isExpired,
        isFalse,
        reason:
            'the child was derived from a deadline with time left, so it starts with time left. '
            'A child born expired would make every derived per-call deadline unusable, which is '
            'the opposite of propagating downward',
      );
      expect(
        childDeadline.remaining,
        const Duration(seconds: 4),
        reason: 'and it has the same four seconds the parent has',
      );

      // The invariant, sampled at two points: a child's remaining is never above its parent's.
      clock.advance(const Duration(seconds: 1));
      expect(childDeadline.remaining, const Duration(seconds: 3));
      expect(parent.deadline.remaining, const Duration(seconds: 3));
      expect(childDeadline.remaining <= parent.deadline.remaining, isTrue);
      // One microsecond before the child expires, neither has expired. `>=` and not `>` on the
      // elapsed reading is what puts the boundary in the right place.
      clock.advance(const Duration(seconds: 3, microseconds: -1));
      expect(childDeadline.isExpired, isFalse);
      expect(parent.deadline.isExpired, isFalse);
      // And exactly on it, both have. A run that reports "one tick left" after it ran out is a
      // transcript an operator cannot read.
      clock.advance(const Duration(microseconds: 1));
      expect(childDeadline.isExpired, isTrue);
      expect(parent.deadline.isExpired, isTrue);
      expect(
        childDeadline.remaining,
        Duration.zero,
        reason: 'clamped, never negative',
      );
      expect(parent.deadline.remaining, Duration.zero);

      // The budget half. §5.1: "The parent reserves the child's limit and all descendant usage
      // settles into the shared ledger; creating a subagent creates no new budget." The test
      // keeps the parent's own budget — there is no second one anywhere in this file's API.
      final budget = CostBudget(maxTokens: 10000, maxUsd: 5.0);
      final reserve = budget.reserve(tokens: 4000, usd: 1.0);
      expect(
        budget.maxTokens,
        10000,
        reason: '§5.1: the ceiling is untouched; a reserve withholds, it does not mint',
      );
      expect(budget.maxUsd, 5.0);
      expect(
        budget.spentTokens,
        4000,
        reason: 'the estimate joins the ledger straight away',
      );
      expect(budget.outstandingReserves, 1);
      expect(
        budget.canAfford(tokens: 6000, usd: 0.0),
        isTrue,
        reason: 'exactly the rest of it fits — the child may spend the last of the budget',
      );
      expect(
        budget.canAfford(tokens: 6001, usd: 0.0),
        isFalse,
        reason:
            'and one token more does not, which is the whole of "never mints"',
      );
      expect(budget.canAfford(tokens: 0, usd: 4.0), isTrue);
      expect(budget.canAfford(tokens: 0, usd: 4.01), isFalse);
      expect(reserve.tokens, 4000);
      expect(reserve.usd, 1.0);

      // The cancel half. §3: "`CancelToken` cascades into the provider stream, tools, the subagent
      // tree and a future Tier 2 process group", and §3.2: it is the protocol package's type,
      // re-exported, not a second implementation — so the only way this half can be true is that
      // the token the child was handed is the *same* type as the parent's.
      final parentCancel = CancelToken();
      final childCancel = parentCancel.derived();
      expect(childCancel.isCancelled, isFalse);
      expect(
        () => parentCancel.cancel(CancelReason('user_interrupt')),
        returnsNormally,
      );
      expect(
        childCancel.isCancelled,
        isTrue,
        reason: 'the cascade reached the child',
      );
      expect(childCancel.reason!.toString(), 'user_interrupt');
      expect(
        childCancel.reason!.toString(),
        parentCancel.reason!.toString(),
        reason: '§3.2: the first reason is the one the whole tree saw',
      );

      // All four together, on the child: the child's own deadline and the parent's shared ledger,
      // its own step limit, and the derived token. The run stops for the one control that fired.
      final child = RunControls(
        deadline: Deadline(
          clock: clock,
          startedAt: clock.now(),
          limit: const Duration(seconds: 30),
        ),
        budget: budget,
        cancel: childCancel,
        steps: StepBudget(maxSteps: 4),
      );
      expect(
        child.stopReason,
        isA<Cancelled>(),
        reason:
            'the deadline and the budget are both fine and the steps are untouched, so the '
            'cancel is the only thing that can be reported',
      );
      expect(child.stopReason!.wireCode!.code, -32031);
      expect(child.deadline.remaining, const Duration(seconds: 30));
      expect(
        child.budget.spentTokens,
        4000,
        reason: 'one ledger for the tree, §5.1',
      );
      expect(child.steps.steps, 0);
    });

    test('the four controls are reported by one question, and the answers are the four', () {
      // The combination the criterion names, one control at a time, on a run that holds all four.
      // Each case starts from the same shape so a reader can see which single trip produced which
      // answer — a table of four is not much, but it is the whole of `task_done`'s vocabulary.
      final cases = <(String, bool, String)>[
        // (label, tripped, the stop it must produce)
        ('cancel', true, 'Cancelled'),
        ('deadline', true, 'DeadlineExceeded'),
        ('budget', true, 'BudgetExhausted'),
        ('steps', true, 'StepLimitReached'),
      ];
      for (final (label, _, expected) in cases) {
        final clock = FakeClock();
        final controls = _controls(clock, maxTokens: 1000, maxSteps: 2);
        switch (label) {
          case 'cancel':
            controls.cancel.cancel(CancelReason('user_interrupt'));
          case 'deadline':
            clock.advance(const Duration(minutes: 1));
          case 'budget':
            controls.budget.settle(
              const AlteriOneUsage(inputTokens: 1000),
              usd: 0.0,
            );
          case 'steps':
            expect(controls.steps.tryStep(), isTrue);
            expect(controls.steps.tryStep(), isTrue);
          default:
            fail('no case named $label');
        }
        expect(controls.stopReason, isNotNull, reason: label);
        expect(_stopName(controls.stopReason), expected, reason: label);
        expect(controls.isTerminal, isTrue, reason: label);
      }

      // And nothing tripped: no stop at all, which is a state the four answers do not cover.
      final clock = FakeClock();
      final controls = _controls(clock, maxTokens: 1000, maxSteps: 2);
      expect(controls.stopReason, isNull);
      expect(controls.isTerminal, isFalse);
    });
  });

  group('the deadline at its boundary', () {
    test('the limit is the boundary, and remaining is never negative', () {
      // §3: "Every run has a mandatory finite `Deadline`." The three edges, in order: before,
      // exactly on, and a long way past. `>=` and not `>` is what puts "exactly on" on the
      // expired side, and clamping is what stops a caller being handed a negative duration to
      // print in `task_done`.
      final clock = FakeClock();
      final deadline = _deadline(clock, const Duration(seconds: 10));

      expect(deadline.limit, const Duration(seconds: 10));
      expect(
        deadline.startedAt,
        clock.now(),
        reason: 'a record, in UTC, for the transcript',
      );
      expect(deadline.startedAt.isUtc, isTrue);
      expect(deadline.isExpired, isFalse);
      expect(deadline.remaining, const Duration(seconds: 10));

      clock.advance(const Duration(milliseconds: 9999));
      expect(
        deadline.isExpired,
        isFalse,
        reason: 'one tick before the limit is not expired',
      );
      expect(deadline.remaining, const Duration(milliseconds: 1));

      clock.advance(const Duration(milliseconds: 1));
      expect(
        deadline.isExpired,
        isTrue,
        reason: 'exactly on the limit is expired',
      );
      expect(deadline.remaining, Duration.zero);

      // Far past it: the clamp, three times over, because the overshoot is not information.
      clock.advance(const Duration(hours: 3));
      expect(deadline.isExpired, isTrue);
      expect(deadline.remaining, Duration.zero, reason: 'never negative');
      expect(deadline.remaining.isNegative, isFalse);
    });

    test(
      'a per-call timeout smaller than what is left is itself the child',
      () {
        // The other direction of `min`, and the one that looks like "the value I passed", so it is
        // the case worth stating: `modelTimeout` of 2s inside a run with 30s left is a 2s deadline.
        final clock = FakeClock();
        final parent = _deadline(clock, const Duration(seconds: 30));
        final child = parent.child(const Duration(seconds: 2));

        expect(child.limit, const Duration(seconds: 2));
        expect(
          child.startedAt,
          clock.now(),
          reason: 'the child starts when it was derived',
        );
        // The child, not the parent, ends two seconds later.
        clock.advance(const Duration(seconds: 2));
        expect(child.isExpired, isTrue);
        expect(
          parent.isExpired,
          isFalse,
          reason: '28 seconds of the run are still left',
        );
        expect(parent.remaining, const Duration(seconds: 28));
        expect(child.remaining, Duration.zero);
      },
    );

    test('the deadline is measured from the run\'s start, not from the clock\'s origin', () {
      // §3.2: "`Deadline` is derived from a monotonic clock and is always finite", and the whole
      // reason [AlteriOneClock] has *two* members is that a deadline is compared against
      // `monotonicNow` — but compared against the reading **the run started at**, not against the
      // clock's zero. `AlteriOneClock.monotonicNow` is documented as "required never to decrease",
      // which says nothing about it starting at zero, so a clock handed to a run may carry an
      // origin of its own: `FakeClock(monotonic: …)` exists to make that case expressible.
      final clock = FakeClock(monotonic: const Duration(seconds: 30));
      final deadline = _deadline(clock, const Duration(seconds: 10));

      expect(
        deadline.isExpired,
        isFalse,
        reason:
            'the run began at monotonic 30s and was given ten seconds, so it has ten seconds. '
            'Measuring from the clock\'s zero makes a fresh deadline born expired',
      );
      expect(deadline.remaining, const Duration(seconds: 10));

      // The same thing one level down, and it is the case the acceptance string names: a child
      // derived from a parent that has already spent part of its time.
      final parent = _deadline(clock, const Duration(minutes: 5));
      clock.advance(const Duration(minutes: 1));
      final child = parent.child(const Duration(seconds: 30));
      expect(child.limit, const Duration(seconds: 30));
      expect(
        child.isExpired,
        isFalse,
        reason:
            'the parent has 4 minutes left and the child asks for 30 seconds, so the child has '
            '30 seconds of its own. It inherits the parent\'s *ceiling*, not the parent\'s '
            'elapsed reading',
      );
      expect(child.remaining, const Duration(seconds: 30));
    });

    test(
      'zero and negative durations are refused rather than read as no timeout',
      () {
        // §3: "`Infinity` and 'no timeout' are not accepted values", and §3.2 makes the refusal
        // concrete: "a `Duration` argument of zero or less is refused at construction rather than
        // producing a deadline that has already expired". Dart has no infinite `Duration`, so zero
        // is the only spelling either of those could take here — which is why it has to be refused
        // by name.
        final clock = FakeClock();
        final refused = <Duration>[
          Duration.zero,
          const Duration(seconds: -1),
          const Duration(days: -365),
        ];
        for (final limit in refused) {
          expect(
            () => _deadline(clock, limit),
            throwsA(
              isA<ArgumentError>()
                  .having((error) => error.name, 'name', 'limit')
                  .having(
                    (error) => error.message.toString(),
                    'message',
                    contains('§3'),
                  ),
            ),
            reason: '$limit is not a limit',
          );
        }
        // The same rule for the per-call argument, under the parameter's own name so the reader can
        // tell the two refusals apart in a stack trace.
        final deadline = _deadline(clock, const Duration(seconds: 10));
        for (final perCall in refused) {
          expect(
            () => deadline.child(perCall),
            throwsA(
              isA<ArgumentError>()
                  .having((error) => error.name, 'name', 'perCall')
                  .having(
                    (error) => error.message.toString(),
                    'message',
                    contains('§3.2'),
                  ),
            ),
            reason: '$perCall is not a per-call timeout',
          );
        }
        // Neither refusal leaves a half-built deadline behind: the parent's ten seconds are intact.
        expect(deadline.remaining, const Duration(seconds: 10));
      },
    );

    test('the wall clock cannot move a deadline, and an expired one cannot lend time', () {
      // Two claims from [AlteriOneClock]'s own documentation, and the reason `FakeClock` has a
      // third mutator at all. A wall clock that jumps forwards would expire a run early and one
      // that jumps backwards would extend it — NTP, a timezone change, a laptop resuming from
      // sleep — and §3.2's "a deadline compared against one extends itself when NTP corrected the
      // host" is the sentence this asserts.
      final clock = FakeClock();
      final deadline = _deadline(clock, const Duration(seconds: 10));

      clock.setWallClock(DateTime.utc(2030, 1, 1));
      expect(
        deadline.isExpired,
        isFalse,
        reason: 'a wall clock an hour ahead is not elapsed',
      );
      expect(deadline.remaining, const Duration(seconds: 10));

      // And backwards, which is the direction that would hand out *more* time than configured.
      clock.setWallClock(DateTime.utc(2000));
      expect(deadline.isExpired, isFalse);
      expect(deadline.remaining, const Duration(seconds: 10));
      expect(
        deadline.startedAt,
        isNot(DateTime.utc(2000)),
        reason: 'and it did not move the run',
      );

      // The real clock still governs: ten seconds of it, and the run is over.
      clock.advance(const Duration(seconds: 10));
      expect(deadline.isExpired, isTrue);

      // §2's own loop reaches this. Its pseudocode checks `isExpired` and then `await`s a policy
      // evaluation before calling `deadline.child(...)`, so a run whose model turn takes 9.9s of a
      // 10s budget and whose approval prompt takes the last 0.1s arrives here with nothing left.
      // "The caller skipped the check" was true only of a caller that was never written.
      //
      // So an exhausted parent yields the smallest legal child rather than throwing. A `StateError`
      // leaving the loop is neither one of §2's four terminal outcomes nor a result: §3 says an
      // expired deadline is `Timeout(Duration.zero)`, and a crash is not that.
      final exhaustedChild = deadline.child(const Duration(seconds: 1));
      expect(
        exhaustedChild.limit,
        const Duration(microseconds: 1),
        reason:
            'one microsecond: the shortest duration that is not the zero §3.2 refuses at '
            'construction. A child is never given a limit of zero, and it is never given the '
            'caller\'s second either -- the parent had none to give',
      );
      expect(
        exhaustedChild.limit,
        lessThan(const Duration(seconds: 1)),
        reason:
            'and still the clamp: the per-call timeout cannot survive an exhausted parent, '
            'because min(perCall, available) is applied after the clamp, not before it',
      );
      expect(
        exhaustedChild.isExpired,
        isFalse,
        reason:
            'born with a microsecond rather than born dead, so the loop gets to run and the '
            'child expires on its own boundary',
      );
      clock.advance(const Duration(microseconds: 1));
      expect(
        exhaustedChild.isExpired,
        isTrue,
        reason:
            'and then the timeout is reported through the ordinary path, which is what §3 '
            'names, rather than as an exception from the middle of the loop',
      );
      expect(
        exhaustedChild.remaining,
        Duration.zero,
        reason: 'clamped at zero, never negative',
      );

      // §3.2's refusal of a zero or negative per-call timeout is untouched -- that is a bad
      // argument and stays one, whatever state the parent is in.
      expect(
        () => deadline.child(Duration.zero),
        throwsArgumentError,
        reason:
            'and it is refused on an exhausted parent too, so "no timeout" cannot be smuggled '
            'in through the argument that §3.2 closes',
      );
    });
  });

  group('the ledger at its boundary', () {
    test(
      'both ceilings can end the run, and neither is a display of the other',
      () {
        // §3.2: "Tokens and USD are both ceilings and either one can end the run. A run with a
        // generous USD ceiling and a tight token ceiling stops on tokens. Treating the token figure
        // as a derived display of the USD one would make the tighter of the two the only limit that
        // exists." So the two cases below are the same shape with the ceilings swapped: in each,
        // the stop is the *tight* one and the other ceiling is nowhere near reached.
        final tokenBound = CostBudget(maxTokens: 100, maxUsd: 1000.0);
        expect(tokenBound.canAfford(tokens: 100, usd: 0.0), isTrue);
        expect(
          tokenBound.canAfford(tokens: 101, usd: 0.0),
          isFalse,
          reason: 'a ceiling is the most a run may spend, not the most it may still afford',
        );
        tokenBound.settle(const AlteriOneUsage(inputTokens: 100), usd: 0.01);
        expect(tokenBound.spentTokens, 100, reason: 'exactly on the ceiling');
        expect(
          tokenBound.isExhausted,
          isTrue,
          reason: '`>=`, so reaching it is exhaustion',
        );
        expect(
          tokenBound.spentUsd,
          closeTo(0.01, 1e-9),
          reason: 'and the generous ceiling is nowhere near reached',
        );
        expect(tokenBound.maxUsd, 1000.0);

        final usdBound = CostBudget(maxTokens: 1000000, maxUsd: 1.0);
        expect(usdBound.canAfford(tokens: 0, usd: 1.0), isTrue);
        expect(
          usdBound.canAfford(tokens: 0, usd: 1.01),
          isFalse,
          reason: 'one cent over the USD ceiling does not fit either',
        );
        usdBound.settle(const AlteriOneUsage(inputTokens: 1), usd: 1.0);
        expect(usdBound.isExhausted, isTrue);
        expect(
          usdBound.spentTokens,
          1,
          reason: 'and the generous token ceiling is nowhere near reached',
        );
        expect(
          usdBound.spentUsd,
          closeTo(1.0, 1e-9),
          reason: 'exactly on the USD ceiling',
        );

        // And the two are genuinely independent numbers rather than one reaching the other: a
        // budget with only tokens has no USD ceiling to fall back on, and the other way round.
        final tokensOnly = CostBudget(maxTokens: 5);
        expect(tokensOnly.maxUsd, isNull);
        expect(tokensOnly.maxTokens, 5);
        final usdOnly = CostBudget(maxUsd: 2.5);
        expect(usdOnly.maxTokens, isNull);
        expect(usdOnly.maxUsd, 2.5);
        // §3 and §5.1: "a missing limit is a configuration error, not infinity". A budget with
        // neither ceiling is refused at construction rather than answering a shrug to `canAfford`.
        expect(() => CostBudget(), throwsArgumentError);
      },
    );

    test('a ceiling is not a reservation: settling more than estimated goes over it', () {
      // §3.2: "An estimate is checked before the call and the real usage settles after it …
      // so a turn that costs more than it estimated leaves the ledger over its ceiling, and that
      // is correct: the ledger records what happened rather than what was hoped for." A budget
      // that clamped at its ceiling would report a spend that never happened, and every figure
      // derived from it — an operator's invoice estimate, a transcript's cost line — would be
      // wrong in the direction that looks cheaper.
      final budget = CostBudget(maxTokens: 100, maxUsd: 1.0);

      // The estimate fits, and then the turn costs half as much again.
      expect(budget.canAfford(tokens: 100, usd: 1.0), isTrue);
      budget.settle(
        const AlteriOneUsage(inputTokens: 60, outputTokens: 90),
        usd: 1.5,
      );

      expect(
        budget.spentTokens,
        150,
        reason: '`totalTokens` is derived, input + output',
      );
      expect(
        budget.spentTokens,
        greaterThan(budget.maxTokens!),
        reason: 'the ledger is over its ceiling, and that is the point',
      );
      expect(budget.spentUsd, closeTo(1.5, 1e-9));
      expect(budget.isExhausted, isTrue);
      // The ceiling did not move to meet the spend. That is the other half of §3's "cannot
      // bypass `CostBudget` … through an internal API", and it is asserted at runtime rather
      // than read off a signature.
      expect(budget.maxTokens, 100);
      expect(budget.maxUsd, 1.0);

      // Usage accumulates rather than replacing: a run's ledger is the sum of its turns, and
      // `AlteriOneUsage.operator +` is how, so a caller aggregating by hand cannot get
      // `cachedInputTokens` wrong in a way the ledger would then hide.
      budget.settle(
        const AlteriOneUsage(inputTokens: 10, cachedInputTokens: 4),
        usd: 0.0,
      );
      expect(budget.spentTokens, 160);
      // A negative count is not a usage, and a ledger that accepted one would hand back budget
      // that was never there.
      expect(
        () => budget.canAfford(tokens: -1, usd: 0.0),
        throwsA(isA<ArgumentError>()),
      );
      for (final bad in <double>[double.nan, double.infinity, -0.01]) {
        expect(
          () => budget.settle(const AlteriOneUsage(inputTokens: 1), usd: bad),
          throwsA(isA<ArgumentError>()),
          reason: '$bad is not an amount of US dollars',
        );
      }
      expect(
        () => CostBudget(maxUsd: double.infinity),
        throwsArgumentError,
        reason: '§3: "Infinity … [is] not [an] accepted value"',
      );
    });

    test('a reserve comes out of the parent\'s remaining and a dead child gives it back', () {
      // §5.1: "The parent reserves the child's limit and all descendant usage settles into the
      // shared ledger; creating a subagent creates no new budget", and the consequence §3.2 spells
      // out: "a reserve that is never settled — because the child died — is returned, or the
      // parent's budget would drift downwards for a run that spent nothing."
      final budget = CostBudget(maxTokens: 10000, maxUsd: 5.0);
      final reserve = budget.reserve(tokens: 4000, usd: 1.0);

      expect(
        reserve.reserveId,
        1,
        reason: 'a counter, so a replayed run numbers them alike',
      );
      expect(reserve.tokens, 4000);
      expect(reserve.usd, 1.0);
      expect(
        reserve.usdMicros,
        1000000,
        reason: 'the ledger counts micro-dollars, exactly',
      );
      expect(budget.spentTokens, 4000);
      expect(budget.outstandingReserves, 1);
      expect(budget.maxTokens, 10000, reason: 'and the ceiling is untouched');

      // A child that spent less than it was given. One call does both halves: the withheld
      // estimate comes off, the real usage goes on, and the difference is the parent's again.
      budget.settleReserve(
        reserve,
        const AlteriOneUsage(inputTokens: 1000, outputTokens: 500),
        usd: 0.25,
      );
      expect(budget.spentTokens, 1500);
      expect(budget.spentUsd, closeTo(0.25, 1e-9));
      expect(budget.outstandingReserves, 0);
      // Settling twice would take the estimate off twice and hand back money nobody spent.
      expect(
        () => budget.settleReserve(
          reserve,
          const AlteriOneUsage(inputTokens: 1),
          usd: 0.0,
        ),
        throwsStateError,
      );
      expect(() => budget.releaseReserve(reserve), returnsNormally);
      expect(
        budget.releaseReserve(reserve),
        isFalse,
        reason: 'nothing left to return',
      );
      expect(
        budget.spentTokens,
        1500,
        reason: 'and a second release does not mint either',
      );

      // A child that spent more than it was given leaves the ledger over, for the same reason a
      // turn does. §3.2's rule applied to a reserve rather than to a call.
      final over = budget.reserve(tokens: 4000, usd: 1.0);
      expect(
        budget.spentTokens,
        5500,
        reason: '1500 already, plus the 4000 withheld',
      );
      budget.settleReserve(
        over,
        const AlteriOneUsage(inputTokens: 6000),
        usd: 1.2,
      );
      // The withheld 4000 comes off and the real 6000 goes on, so the ledger rises by the
      // difference rather than by both.
      expect(
        budget.spentTokens,
        7500,
        reason: '1500 spent + 6000 the child actually used',
      );
      expect(
        budget.isExhausted,
        isFalse,
        reason: 'the ceiling is 10000 and the child spent 2000 more than it was given',
      );

      // A child that died: the reserve is returned whole, and `false` rather than a throw because
      // returning is what a teardown does on every path, cancelled-before-it-started included.
      // 2000 and not the 3000 this paragraph originally said: the reserve is checked against the
      // ledger, so a reserve that does not fit is a `StateError` and never reaches the assertion
      // about what releasing it does. 7500 + 2000 fits inside the 10000 ceiling.
      final dying = budget.reserve(tokens: 2000, usd: 1.0);
      expect(budget.spentTokens, 9500);
      expect(budget.releaseReserve(dying), isTrue);
      expect(
        budget.spentTokens,
        7500,
        reason: 'the parent is back to what it actually spent',
      );
      expect(budget.outstandingReserves, 0);

      // A reserve that does not fit is a refusal rather than a null, because it is the *state*
      // that answers: §2 checks the budget before it starts a child and reports `-32032`. Note
      // that `canAfford` is the question and `reserve` is the action — §2's pseudocode writes
      // `canReserve(...)` before a separate reserve, and this type collapses the two so there is
      // no window for a caller to interleave something into.
      expect(
        budget.canAfford(tokens: 4000, usd: 4.0),
        isFalse,
        reason:
            'the parent is back to 7500 after the release, so 7500 + 4000 = 11500 is past the '
            '10000 ceiling. An earlier draft asserted true against a 6000 that no longer exists '
            'once the dead child handed its reserve back',
      );
      expect(
        () => budget.reserve(tokens: 4001, usd: 0.0),
        throwsStateError,
        reason: 'one token more than is left',
      );
      expect(
        budget.spentTokens,
        7500,
        reason: 'a refused reserve withholds nothing',
      );
      expect(budget.outstandingReserves, 0);
      // A reserve from another budget is not this budget's business to settle. Its own case is
      // the next test, because it needs a ledger whose first reserve is still outstanding.
      final other = CostBudget(maxTokens: 1000);
      final foreign = other.reserve(tokens: 10, usd: 0.0);
      expect(
        () => budget.settleReserve(foreign, const AlteriOneUsage(), usd: 0.0),
        throwsStateError,
      );
      expect(
        other.outstandingReserves,
        1,
        reason: 'and it is still outstanding over there',
      );
    });

    test('a handle from another budget is refused even when its id collides', () {
      // `reserveId` is a counter local to one budget, so **every** budget's first reserve is id
      // 1 and two runs in one process collide on the first child rather than occasionally. That
      // makes an id-keyed lookup accept a foreign handle exactly when it must not: the refund and
      // the settle both remove by id, so run B's handle would release run A's live reservation
      // while A's child is still holding it. The private constructor stops a handle being minted;
      // this is the half a caller actually controls, which is handing one over.
      //
      // The premise is asserted rather than assumed. An earlier draft of this case ran against a
      // ledger with no outstanding reserves, so the lookup missed and the throw came from
      // emptiness — which a check against emptiness passes, against an implementation with no
      // ownership test at all.
      final mine = CostBudget(maxTokens: 1000);
      final theirs = CostBudget(maxTokens: 1000);
      final local = mine.reserve(tokens: 400, usd: 0.0);
      final foreign = theirs.reserve(tokens: 400, usd: 0.0);
      expect(
        local.reserveId,
        foreign.reserveId,
        reason:
            'the premise: both ledgers number from 1, so both handles name the same key. '
            'If this ever stops being true this case is no longer testing what it claims to',
      );
      expect(
        mine.outstandingReserves,
        1,
        reason: 'a live entry under that key',
      );
      expect(
        () => mine.settleReserve(foreign, const AlteriOneUsage(), usd: 0.0),
        throwsStateError,
        reason:
            'the ledger holds a live reserve under this key, so the refusal is the handle '
            'being foreign and not the key being absent',
      );
      expect(
        mine.releaseReserve(foreign),
        isFalse,
        reason:
            'returning one is refused the same way, because it would refund the live '
            "child's estimate while that child is still holding its own",
      );
      expect(
        mine.outstandingReserves,
        1,
        reason: 'the local reserve survived both attempts, and a rejected call changes nothing',
      );
      expect(
        mine.spentTokens,
        400,
        reason: 'the foreign handle neither consumed the live entry nor added its own usage',
      );
      expect(
        theirs.outstandingReserves,
        1,
        reason: 'and the other ledger is untouched by the attempt',
      );
      // The owner still settles its own reserve normally, so the refusals above are about the
      // handle and not about a ledger that has stopped working.
      mine.settleReserve(
        local,
        const AlteriOneUsage(inputTokens: 40),
        usd: 0.0,
      );
      expect(
        mine.spentTokens,
        40,
        reason: 'the 400 withheld came off and the 40 actually used went on',
      );
    });
  });

  group('one step is one model turn', () {
    test('the last permitted step is taken and the next one is refused', () {
      // §3.1's first row: "One **step** | One model turn, counted once regardless of how many
      // tool calls it requested." A loop that counted tool calls would end a run eight times too
      // early while reporting a progress story the specification does not tell, which is why this
      // is a class rather than a counter the loop increments wherever it finds convenient.
      final steps = StepBudget(maxSteps: 3);
      expect(steps.maxSteps, 3);
      expect(steps.steps, 0);
      expect(steps.isExhausted, isFalse);

      // A turn that requested eight tool calls is still one step. Nothing in this API accepts a
      // tool-call count, which is the mechanical form of §3.1's "counted once"; so the loop's
      // only move is to take the turn, and the eight calls are simply not an argument.
      for (var turn = 1; turn <= 3; turn++) {
        expect(
          steps.tryStep(),
          isTrue,
          reason: 'turn $turn is inside the limit',
        );
        expect(steps.steps, turn);
      }
      expect(
        steps.isExhausted,
        isTrue,
        reason: 'the third permitted turn has been taken',
      );

      // The fourth is refused, and refused *without moving the counter*. A counter that went past
      // its own ceiling makes `steps` a number no transcript can reconcile.
      expect(steps.tryStep(), isFalse);
      expect(
        steps.steps,
        3,
        reason: 'a refused step leaves the count where it was',
      );
      expect(steps.isExhausted, isTrue);
      expect(
        steps.tryStep(),
        isFalse,
        reason: 'and asking twice is still refused',
      );

      // The other spelling of the same boundary throws rather than returning false, for a caller
      // that increments as it goes and wants the number. Both spellings agree on the state.
      expect(() => steps.nextStep(), throwsStateError);
      expect(steps.steps, 3);

      // And a positive limit is required. §5.1: "a missing limit is a configuration error, not
      // infinity"; a zero is the limit that would let a run start one turn and then stop, so the
      // type refuses it rather than accepting a configuration that happens to be typed.
      for (final bad in <int>[0, -1]) {
        expect(
          () => StepBudget(maxSteps: bad),
          throwsA(
            isA<ArgumentError>()
                .having((error) => error.name, 'name', 'maxSteps')
                .having(
                  (error) => error.message.toString(),
                  'message',
                  contains('§5.1'),
                ),
          ),
          reason: '$bad is not a step limit',
        );
      }
      // A limit of one is a run that gets exactly one model turn, and that is not degenerate.
      final single = StepBudget(maxSteps: 1);
      expect(single.tryStep(), isTrue);
      expect(single.isExhausted, isTrue);
      expect(single.nextStep, throwsStateError);
    });
  });

  group('the stagnation detector', () {
    test('the same signature window times in a row trips it, and success does not reset it', () {
      // §3.1: "The same tool with canonically identical arguments `stagnationWindow` times in a
      // row is stagnation and stops the run, even if the model varies its reasoning text."
      final detector = StagnationDetector(window: 3);
      expect(detector.window, 3);
      expect(
        detector.isStagnant,
        isFalse,
        reason: 'an empty window is not stagnation',
      );
      expect(detector.recorded, 0);
      expect(
        detector.lastSignature,
        isNull,
        reason: 'nothing has been recorded yet',
      );

      expect(detector.record('web.search', '{"q":"al"}'), isFalse);
      expect(detector.record('web.search', '{"q":"al"}'), isFalse);
      expect(
        detector.recorded,
        2,
        reason: 'the window is filling, not yet full of one thing',
      );
      expect(
        detector.isStagnant,
        isFalse,
        reason: 'a partially filled window never trips',
      );

      // The third is the boundary: three in a row is what §3.1's `stagnationWindow` means.
      expect(detector.record('web.search', '{"q":"al"}'), isTrue);
      expect(detector.isStagnant, isTrue);
      expect(
        detector.recorded,
        3,
        reason: 'the window holds exactly `window` signatures',
      );
      expect(
        detector.lastSignature,
        isNotNull,
        reason: '§2 quotes it in the stopping event',
      );
      expect(
        detector.lastSignature,
        StagnationDetector.signatureOf('web.search', '{"q":"al"}'),
      );

      // **The subtle half, asserted on its own.** §3.1: "A different signature, a different tool,
      // or a terminal outcome resets the window. A successful `ToolOutcome.ok` does **not** reset
      // it — the loop, not the outcome, is the signal." Every one of those three calls above
      // could have *succeeded*, and the window is untouched, because this type has no member that
      // takes an outcome at all: there is nothing for a successful `ToolOutcome` to call. The
      // assertion is therefore about the state surviving three successful turns, and the surface
      // check in the last test of this group is what makes it structural rather than a matter of
      // nobody having called anything yet.
      expect(
        detector.isStagnant,
        isTrue,
        reason: 'three successes in a row are still a loop',
      );
      expect(detector.recorded, 3);

      // §3.1's one reset that is a member: a **terminal** outcome. The loop calls `reset()` when
      // the run ends, so a detector reused for the next run does not inherit the last one's
      // window — and `lastSignature` is deliberately kept, because that is the evidence the
      // terminal event quotes.
      final stoppedAt = detector.lastSignature;
      detector.reset();
      expect(detector.isStagnant, isFalse);
      expect(detector.recorded, 0);
      expect(
        detector.lastSignature,
        stoppedAt,
        reason: 'clearing it would erase the evidence at the moment it is written down',
      );
      // A reused detector that then loops again trips again, on the same window.
      expect(detector.record('web.search', '{"q":"al"}'), isFalse);
      expect(detector.record('web.search', '{"q":"al"}'), isFalse);
      expect(detector.record('web.search', '{"q":"al"}'), isTrue);
    });

    test('a different tool or arguments clears the window, and 1 and 2 are refused', () {
      // §3.1's other two resets, which are *not* members: "a different signature, a different
      // tool … resets the window", read as a ring of the last `window` signatures rather than as
      // a flag somebody has to clear. So the reset is visible as the window sliding.
      final detector = StagnationDetector(window: 3);
      const a = '{"q":"al"}';
      const b = '{"q":"er"}';

      expect(detector.record('web.search', a), isFalse);
      expect(detector.record('web.search', a), isFalse);
      // A different *signature* — same tool, different arguments — slides the ring.
      expect(detector.record('web.search', b), isFalse);
      expect(
        detector.isStagnant,
        isFalse,
        reason: 'the window is [a, a, b], not three of a thing',
      );
      // A different *tool* with the *same* arguments is a different signature too, because the
      // signature is over `toolId ‖ canonicalArgsJson` and not over the arguments alone. The
      // three distinct signatures recorded so far are named, because the ring is easier to
      // follow with them than with the arguments they came from:
      //
      //   s1 = (web.search, a)   s2 = (web.search, b)   s3 = (web.fetch, a)
      //
      // and the window is the last three pushed, so after [s1, s1, s2] the next record slides
      // the oldest out rather than appending a fourth.
      expect(detector.record('web.fetch', a), isFalse);
      expect(
        detector.isStagnant,
        isFalse,
        reason: 'the window is [s1, s2, s3], all different',
      );
      expect(detector.record('web.fetch', a), isFalse);
      expect(
        detector.isStagnant,
        isFalse,
        reason:
            'the window is [s2, s3, s3] — two of one thing and one of another',
      );
      expect(
        detector.record('web.fetch', a),
        isTrue,
        reason: 'the window is [s3, s3, s3]: three turns of the same tool with the same args',
      );
      expect(
        detector.recorded,
        3,
        reason: 'and `recorded` has not grown past the window',
      );
      // And the ring slides rather than growing: a fourth record leaves three in the window.
      detector.reset();
      for (var turn = 0; turn < 4; turn++) {
        detector.record('web.search', a);
      }
      expect(
        detector.recorded,
        3,
        reason: 'the window is `window` long, not unbounded',
      );
      expect(
        detector.isStagnant,
        isTrue,
        reason:
            'four in a row leaves the ring holding the last three, which are all the same. A '
            'window that grew instead of sliding would report four and a detector reading it '
            'would be counting history rather than the configured window',
      );

      // §3.1: "a legitimate retry of a transient failure with identical arguments does trip the
      // detector, which is why `stagnationWindow` should be at least 3". A window of 1 would end
      // a run on one call and a window of 2 on one retry, so the factory refuses both and cites
      // the section's own advice rather than a number invented here.
      for (final bad in <int>[0, 1, 2, -1]) {
        expect(
          () => StagnationDetector(window: bad),
          throwsA(
            isA<ArgumentError>()
                .having((error) => error.name, 'name', 'window')
                .having(
                  (error) => error.message.toString(),
                  'message',
                  allOf(contains('§3.1'), contains('at least 3')),
                ),
          ),
          reason: '$bad is not a window',
        );
      }
      expect(
        StagnationDetector(window: 3).window,
        3,
        reason: 'three is allowed',
      );
      // An unresolved tool id is a bug at the boundary, not a run that stagnates for the wrong
      // reason, and a signature over no tool separates nothing.
      expect(
        () => StagnationDetector(window: 3).record('', '{}'),
        throwsA(
          isA<ArgumentError>().having((error) => error.name, 'name', 'toolId'),
        ),
      );
    });

    test('the signature is SHA-256 of the tool id and the canonical args, with no separator', () {
      // §3.1: "**Stagnation signature** | `SHA-256(toolId ‖ canonicalArgsJson)`". There is no
      // `package:crypto` in this package's dependency graph, so `control.dart` implements
      // SHA-256 privately; a hand-written hash is exactly the case where "deterministic" and
      // "correct" look identical from inside, so these are the **published FIPS 180-4 vectors**
      // rather than a second implementation to agree with.
      //
      // `signatureOf('', …)` is how a published vector is reachable through an API whose two
      // arguments are both non-empty in real use: the concatenation carries no separator, so an
      // empty tool id makes the message exactly the arguments.
      expect(
        StagnationDetector.signatureOf('', ''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        reason: 'SHA-256 of the empty string',
      );
      expect(
        StagnationDetector.signatureOf('', 'abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        reason: 'SHA-256("abc")',
      );
      expect(
        StagnationDetector.signatureOf('abc', ''),
        StagnationDetector.signatureOf('', 'abc'),
        reason: 'no separator, so the split between the two arguments does not exist',
      );

      // The padding boundary, which is where a private implementation actually breaks. A 64-byte
      // message needs the 0x80 byte and the length in a second block; 55 is the last length that
      // fits both in one; 56 is the first that does not. Each row is (total length, digest),
      // computed by an outside authority, and a **list of records** because the length repeats
      // nowhere but a map keyed by anything but the length would be the wrong shape anyway.
      final vectors = <(int, String)>[
        (
          54,
          '3fc19d5306c4935cd6855c5e680d1440d98903577def7f69de2c1a984c54168d',
        ),
        (
          55,
          '8b14771abbc514c8b2e3c30cd445349b9fd2c50a7b659661b04a1bfb7c3a49e3',
        ),
        (
          56,
          'd564f010e8bdd2349ebd44654c071ff8c8802fd05c1bd3c36173fbea15edf1a7',
        ),
        (
          57,
          '2563229127af390abb26889423a962abd300872dabb4740851a609c8d57f8003',
        ),
        (
          63,
          'eab215adb2f9c1b0a701783523cece98d0c3b9d00a5864520681bb3eca66a486',
        ),
        (
          64,
          'f5c270175cb5280a7f46fa848ffe51e07961f4ad6610ec40fef454a579c3ea2c',
        ),
        (
          65,
          '0d8b68ce652d54ecccb8cee85cd2bd84767810ae6d58917a4394030671e3b4d7',
        ),
        (
          119,
          '9a5ae5133cf130017406a442e021150a5732539ef469b3ddaebe38fa0e7bd701',
        ),
        (
          120,
          '3e0454e3108835d895096b8985bd64d7d2243f33e2e075ee71866222595b929d',
        ),
        (
          127,
          'bb09bf727925b1e21a3d660b9b8b57fccb6c22fc9c5da4e215c49327f8c573c4',
        ),
        (
          128,
          '293c417b230c9ca0cabd16544bb3427f33ea6875f4ba8c0b2fd169202778c3c8',
        ),
      ];
      const toolId = 'web.search';
      for (final (length, expected) in vectors) {
        // `toolId` is 11 bytes and the canonical JSON document is 8 bytes plus its filler, so the
        // filler is what makes the *concatenation* the requested length.
        final args = '{"a":"${'x' * (length - toolId.length - 8)}"}';
        expect(
          toolId.length + args.length,
          length,
          reason: 'the vector for $length is built at $length bytes',
        );
        expect(
          StagnationDetector.signatureOf(toolId, args),
          expected,
          reason:
              'SHA-256 over $length bytes, toolId + canonical args, no separator',
        );
      }

      // The definition is the *whole message*: a different tool id or different arguments is a
      // different signature, and there is no length prefix, no namespace and no tool version in
      // it — §3.1's grammar admits nothing else.
      expect(
        StagnationDetector.signatureOf('web.search', '{"q":"al"}'),
        isNot(StagnationDetector.signatureOf('web.search', '{"q":"a1"}')),
      );
      expect(
        StagnationDetector.signatureOf('web.search', '{}'),
        isNot(StagnationDetector.signatureOf('web.fetch', '{}')),
      );
      expect(
        StagnationDetector.signatureOf('web.search', '{}').length,
        64,
        reason: 'lowercase hex of a 256-bit digest',
      );
      expect(
        StagnationDetector.signatureOf('web.search', '{}'),
        StagnationDetector.signatureOf('web.search', '{}').toLowerCase(),
      );

      // **Why the separator-less concatenation is safe**, which is a claim about the *grammar*
      // rather than about the hash: `canonicalArgsJson` is a JSON object and therefore starts
      // with `{`, and `concepts.md` §2's tool-id grammar admits no `{`, so the first `{` in the
      // message fixes the split and no pair of (tool id, arguments) can produce the same bytes
      // as a different pair. Asserted against the grammar the product actually ships rather than
      // against the prose, because a widened grammar would break the digest's injectivity
      // silently — a collision is two runs reporting one another's stagnation.
      expect(toolIdGrammar.hasMatch('web.search'), isTrue);
      expect(toolIdGrammar.hasMatch('{'), isFalse);
      expect(toolIdGrammar.hasMatch('{"a":1}'), isFalse);
      expect(
        'web.search{"a":1}'.indexOf('{'),
        'web.search'.length,
        reason: 'and the split is therefore at a position the grammar fixes',
      );
    });
  });

  group('precedence, and what is not an outcome', () {
    test('when more than one control has fired, the order is cancel, deadline, budget, steps', () {
      // §2 checks its four controls in exactly this order, twice, in the pseudocode that
      // predates the file; `task_done` reports the one that fired, so the order is a claim a
      // transcript can be wrong about rather than an implementation detail.
      //
      // The whole truth table, all sixteen combinations, and **not** two or three pairs: a
      // precedence demonstrated on two simultaneous stops says nothing about the other fourteen
      // orderings, and the rows where exactly one control fires are what say the four answers are
      // four answers rather than one.
      final cases = <(bool, bool, bool, bool, String)>[
        // (cancel, deadline, budget, steps) -> the stop that must be reported
        (true, true, true, true, 'Cancelled'),
        (true, true, true, false, 'Cancelled'),
        (true, true, false, true, 'Cancelled'),
        (true, true, false, false, 'Cancelled'),
        (true, false, true, true, 'Cancelled'),
        (true, false, true, false, 'Cancelled'),
        (true, false, false, true, 'Cancelled'),
        (true, false, false, false, 'Cancelled'),
        (false, true, true, true, 'DeadlineExceeded'),
        (false, true, true, false, 'DeadlineExceeded'),
        (false, true, false, true, 'DeadlineExceeded'),
        (false, true, false, false, 'DeadlineExceeded'),
        (false, false, true, true, 'BudgetExhausted'),
        (false, false, true, false, 'BudgetExhausted'),
        (false, false, false, true, 'StepLimitReached'),
        (false, false, false, false, 'none'),
      ];

      for (final (cancel, deadline, budget, steps, expected) in cases) {
        final label =
            'cancel=$cancel deadline=$deadline budget=$budget steps=$steps';
        final clock = FakeClock();
        final controls = _controls(clock, maxTokens: 1000, maxSteps: 2);
        if (cancel) controls.cancel.cancel(CancelReason('user_interrupt'));
        if (deadline) clock.advance(const Duration(minutes: 1));
        if (budget) {
          controls.budget.settle(
            const AlteriOneUsage(inputTokens: 1000),
            usd: 0.0,
          );
        }
        if (steps) {
          expect(controls.steps.tryStep(), isTrue, reason: label);
          expect(controls.steps.tryStep(), isTrue, reason: label);
        }
        expect(_stopName(controls.stopReason), expected, reason: label);
        expect(controls.isTerminal, expected != 'none', reason: label);
      }

      // **The choice this file is reporting as a judgement.** The implementation takes cancel
      // first, and that is the only ordering §2's prose supports: cancellation is the one control
      // that arrives from outside the run, so it is the answer a person who pressed Ctrl-C must
      // see rather than a limit the run happened to reach in the same instant. Deadline before
      // budget because a time limit holds whatever the run did with its money. Budget before
      // steps because both are allowances and the step limit is the one bound on a run that is
      // *progressing*.
      //
      // The step limit is also the only one of the four with **no wire code**, and that is not an
      // oversight to be tidied away: [error-codes.md] §1.1 says a variant of an existing failure
      // mode is a diagnostic and not a number, and `EngineDiagnosticCode.engineMaxSteps` says "it
      // is not a spend". It is therefore also the least terminal of the four and goes last.
      final clock = FakeClock();
      final exhausted = _controls(clock, maxTokens: 1000, maxSteps: 1);
      expect(exhausted.steps.tryStep(), isTrue);
      final stopped = exhausted.stopReason;
      expect(stopped, isA<StepLimitReached>());
      expect(
        stopped!.wireCode,
        isNull,
        reason: '§1.1: a diagnostic, not a number',
      );
      expect((stopped as StepLimitReached).steps, 1);
      expect(
        EngineDiagnosticCode.engineMaxSteps.code,
        'engine.max_steps',
        reason: 'the diagnostic that names it, and the four stops below name three codes',
      );

      // And the fields each answer carries, read rather than inferred from the type. **A fresh
      // clock per case**, because `FakeClock` is one object: the case before this one advanced a
      // shared clock past its own one-minute deadline, so reusing it would make every deadline in
      // this block expired before the run began and the cast would find the wrong variant. That
      // is the trap the §2 order above is about — a stop reported for the wrong reason.
      final cancelClock = FakeClock();
      final cancelled = _controls(cancelClock, maxTokens: 1000, maxSteps: 4)
        ..cancel.cancel(CancelReason('user_interrupt'));
      expect(cancelled.stopReason, isA<Cancelled>());
      expect(
        (cancelled.stopReason! as Cancelled).reason.toString(),
        'user_interrupt',
      );
      final deadlineClock = FakeClock();
      final timedOut = _controls(deadlineClock, maxTokens: 1000, maxSteps: 4);
      deadlineClock.advance(const Duration(minutes: 1));
      expect(timedOut.stopReason, isA<DeadlineExceeded>());
      expect(
        (timedOut.stopReason! as DeadlineExceeded).remaining,
        Duration.zero,
      );
      final overspent = _controls(clock, maxTokens: 10, maxSteps: 4)
        ..budget.settle(const AlteriOneUsage(inputTokens: 25), usd: 0.5);
      final over = overspent.stopReason! as BudgetExhausted;
      expect(
        over.spentTokens,
        25,
        reason: '§3.2: the ledger records what happened',
      );
      expect(over.spentTokens, greaterThan(overspent.budget.maxTokens!));
      expect(over.spentUsd, closeTo(0.5, 1e-9));

      // The two controls that are **not** in the union, stated here because their absence is the
      // claim: §3.2 says the step limit and the detector "are separate, and neither subsumes the
      // other", so a run that stopped making progress is not a run that ran out of anything, and
      // `stagnationDetected` (`-32033`) is the protocol package's code rather than one of these
      // four. `RunControls` has no member for it and this switch has no case for it.
      expect(
        DomainErrorCode.stagnationDetected.code,
        -32033,
        reason: 'a separate code, for a separate question',
      );
      expect(DomainErrorCode.stagnationDetected.feedsToModel, isTrue);
    });

    test('a terminal control outcome is not a ToolOutcome, and nothing raises a ceiling', () {
      // §3.2's last bullet: "`-32030`/`-32031`/`-32032` end the run; a tool failure is something
      // the model sees and can correct. Anything that lets a tool return a budget or deadline
      // exhaustion as an ordinary outcome has turned a terminal control decision into a
      // suggestion."
      //
      // The distinction the taxonomy itself draws is **`feedsToModel`**, and it is asserted here
      // rather than described: a code that reaches the model is a correction the model may make,
      // and the three terminal codes do not reach it. `error-codes.md` §1's table is the
      // specification for both flags and `protocol_contract_test.dart` compiles it, so this is a
      // comparison against the declared taxonomy rather than against a number written here.
      expect(DomainErrorCode.deadlineExceeded.code, -32030);
      expect(DomainErrorCode.cancelled.code, -32031);
      expect(DomainErrorCode.budgetExhausted.code, -32032);
      for (final code in <DomainErrorCode>[
        DomainErrorCode.deadlineExceeded,
        DomainErrorCode.cancelled,
        DomainErrorCode.budgetExhausted,
      ]) {
        expect(code.feedsToModel, isFalse, reason: '$code ends the run');
        expect(code.retry, RetryPolicy.no, reason: '$code is not retried into');
      }
      expect(
        DomainErrorCode.toolFailed.feedsToModel,
        isTrue,
        reason: 'the contrast: -32010 is exactly what §3 calls correctable',
      );
      expect(DomainErrorCode.policyDenied.feedsToModel, isTrue);
      expect(DomainErrorCode.approvalDeclined.feedsToModel, isTrue);

      // The three codes arrive **from the protocol package's taxonomy**, as enum constants rather
      // than literals, so a caller writes the name at the call site and the digits live in
      // `error.dart` and nowhere else.
      expect(
        DeadlineExceeded(Duration.zero).wireCode,
        same(DomainErrorCode.deadlineExceeded),
      );
      expect(
        Cancelled(CancelReason('user_interrupt')).wireCode,
        same(DomainErrorCode.cancelled),
      );
      expect(
        BudgetExhausted(0, 0.0).wireCode,
        same(DomainErrorCode.budgetExhausted),
      );
      expect(
        StepLimitReached(1).wireCode,
        isNull,
        reason: '§1.1: no number for a step limit',
      );

      // **Nothing in the union carries a tool's result.** The variants hold a cancel reason, a
      // duration, two spend figures and a turn count — and the exhaustive switch below has no
      // `default`, so a fifth variant would not compile here. That is the strongest form of
      // "nothing in this hierarchy takes a tool's result": a tool would have to be able to build
      // one of these four, and each constructor's arguments are values only the engine holds.
      // Not a `const` list, because `CancelReason` has no constant constructor and §3.1's point
      // is that the reason came from the protocol package's token rather than from here.
      final stop = <RunStopReason>[
        Cancelled(CancelReason('user_interrupt')),
        DeadlineExceeded(Duration.zero),
        BudgetExhausted(1, 2.0),
        StepLimitReached(3),
      ];
      for (final reason in stop) {
        final rendered = switch (reason) {
          Cancelled(:final reason) => 'cancelled $reason',
          DeadlineExceeded(:final remaining) => 'deadline $remaining',
          BudgetExhausted(:final spentTokens, :final spentUsd) =>
            'budget $spentTokens/$spentUsd',
          StepLimitReached(:final steps) => 'steps $steps',
        };
        expect(rendered, isNotEmpty);
        // **The variant's one field, typed.** The exhaustive switch above is the real proof — a
        // fifth variant would not compile — so what is left to assert is the shape of each
        // payload. An earlier draft asserted `isNot(contains('outcome'))` on the rendered string,
        // which could not fail without the switch itself changing and which read as though the
        // block proved more than it did. A field typed `AlteriOneToolOutcome` *would* fail here,
        // and would fail at exactly the moment a tool's result became reachable.
        //
        // `(field, actual, expected)` records rather than one "any primitive" matcher, because a
        // list of what is *allowed* is weaker than each field naming what it must *be*: a field
        // typed `AlteriOneToolOutcome` would be absent from the allowed list rather than equal to
        // any entry, and the line for its own variant says which type was expected instead. `Type`
        // values are compared as types, not through `isA` — `actual` is a `Type`, and
        // `isA<Duration>()` would ask whether the *value* is a Duration, which `Duration` is not.
        //
        // The switch below is exhaustive with no `default`, so a fifth variant fails to compile
        // here rather than quietly contributing no rows — the same argument the outer switch makes.
        final payloadTypes = switch (reason) {
          Cancelled(:final reason) => <(String, Type, Type)>[
            ('reason', reason.runtimeType, CancelReason),
          ],
          DeadlineExceeded(:final remaining) => <(String, Type, Type)>[
            ('remaining', remaining.runtimeType, Duration),
          ],
          // Two figures, listed one at a time: a record has no single type object to name, and
          // naming both is what pins "two spend figures and nothing else".
          BudgetExhausted(:final spentTokens, :final spentUsd) =>
            <(String, Type, Type)>[
              ('spentTokens', spentTokens.runtimeType, int),
              ('spentUsd', spentUsd.runtimeType, double),
            ],
          StepLimitReached(:final steps) => <(String, Type, Type)>[
            ('steps', steps.runtimeType, int),
          ],
        };
        for (final (field, actual, expected) in payloadTypes) {
          expect(
            actual,
            expected,
            reason:
                '$reason.$field is a value the engine holds, so a tool cannot build one',
          );
        }
      }

      // **And there is no method anywhere on the surface that raises a ceiling.** §3: "Model,
      // tool and subagent cannot bypass `CostBudget`, deadline, cancellation or policy through an
      // internal API." The absence of the method *is* the invariant, so it is asserted as an
      // exact member list per type rather than as a comment: a new `raise`, `withCeiling` or
      // `grant` would show up here, and so would any member that could not be reasoned about at
      // all.
      final root = _repositoryRoot();
      final surfaces = <(String, List<String>)>[
        (
          'Deadline',
          <String>[
            'child',
            'isExpired',
            'limit',
            'remaining',
            'startedAt',
            'toString',
          ],
        ),
        (
          'CostBudget',
          <String>[
            'canAfford',
            'isExhausted',
            'maxTokens',
            'maxUsd',
            'outstandingReserves',
            'releaseReserve',
            'reserve',
            'settle',
            'settleReserve',
            'spentTokens',
            'spentUsd',
            'spentUsdMicros',
            'toString',
          ],
        ),
        (
          'StepBudget',
          <String>[
            'isExhausted',
            'maxSteps',
            'nextStep',
            'steps',
            'toString',
            'tryStep',
          ],
        ),
        (
          'StagnationDetector',
          <String>[
            'isStagnant',
            'lastSignature',
            'record',
            'recorded',
            'reset',
            'signatureOf',
            'toString',
            'window',
          ],
        ),
        (
          // Sorted like the parsed list, so a failure prints one difference rather than
          // a cascade of shifted elements. `steps` is the `StepBudget` field and nothing
          // here widens it: `RunControls` holds the four controls and has no member
          // that could raise one, which is §3's "cannot raise the limit" at the level
          // of the composite.
          'RunControls',
          <String>[
            'budget',
            'cancel',
            'deadline',
            'isTerminal',
            'steps',
            'stopReason',
            'toString',
          ],
        ),
      ];
      for (final (type, expected) in surfaces) {
        expect(
          _publicMembers(type, root)..sort(),
          expected,
          reason:
              '$type\'s public surface. There is no member that raises a limit, widens a window '
              'or settles on an outcome, so §3 holds because there is nothing to call rather '
              'than because three call sites each remembered',
        );
      }

      // Two more absences that a signature check would not give on its own. First, no setter
      // anywhere in the file: every ceiling is a `final` field reached through a getter, so
      // there is no reassignment for anything to do even if a member were added.
      expect(
        RegExp(
          r'^\s*set\s+[A-Za-z_]',
          multiLine: true,
        ).hasMatch(_code(_controlSource(root))),
        isFalse,
        reason: 'no setter in control.dart, so no field can be rewritten from outside',
      );
      // Third, and the one the list above cannot reach: no extension on any of the five. An
      // extension is resolved statically rather than inherited, so `final class` does not stop one
      // — `extension CostBudgetX on CostBudget { void raise(int by) { … } }` compiles, is callable
      // by anyone holding the type, and adds nothing to the member list above. Asserted here
      // because "nothing raises a ceiling" has to mean it for the door as well as the room.
      expect(
        _extensionsOn(root, const <String>[
          'CostBudget',
          'Deadline',
          'StepBudget',
          'StagnationDetector',
          'RunControls',
        ]),
        isEmpty,
        reason:
            'no extension on any of the five controls. An extension is resolved statically '
            'rather than inherited, so `final class` does not prevent one and a `raise` added '
            'this way would be callable by every holder of the type while being invisible to the '
            'member list above',
      );
      // Second, the runtime proof that the ceilings did not move under any operation the ledger
      // offers: `maxTokens` and `maxUsd` are the same values after a reserve that withholds, a
      // settlement that returns the difference and hands back more than it took, and a release
      // that returns the whole thing.
      final budget = CostBudget(maxTokens: 1000, maxUsd: 10.0);
      final reserve = budget.reserve(tokens: 500, usd: 5.0);
      expect(
        budget.maxTokens,
        1000,
        reason: 'a reserve withholds; it does not move the ceiling',
      );
      expect(budget.maxUsd, 10.0);
      expect(budget.spentTokens, 500);

      // The child spent 1200 against the 500 withheld, so the ledger is *over* the token
      // ceiling — §3.2's rule again, applied to a reserve rather than to a call — and the ceiling
      // itself has not moved to meet it.
      budget.settleReserve(
        reserve,
        const AlteriOneUsage(inputTokens: 1200),
        usd: 0.9,
      );
      expect(budget.spentTokens, 1200);
      expect(budget.spentTokens, greaterThan(budget.maxTokens!));
      expect(budget.isExhausted, isTrue);
      expect(budget.maxTokens, 1000, reason: 'and the ceiling is still 1000');
      expect(budget.maxUsd, 10.0);

      // A child that died on a budget with room left, so the reserve is granted and can be
      // released. The numbers are 10000 rather than the 1000 above so this reserve fits at all:
      // the ledger is over its ceiling, and a reserve that does not fit is refused rather than
      // truncated, which is itself the property.
      final roomy = CostBudget(maxTokens: 10000, maxUsd: 100.0);
      final dying = roomy.reserve(tokens: 100, usd: 1.0);
      expect(roomy.spentTokens, 100);
      expect(roomy.maxTokens, 10000);
      expect(roomy.releaseReserve(dying), isTrue);
      expect(
        roomy.spentTokens,
        0,
        reason: 'a run that spent nothing has spent nothing',
      );
      expect(roomy.maxTokens, 10000);
      expect(roomy.maxUsd, 100.0);
    });

    test(
      'the public barrel exports every control, including the cancel token',
      () {
        // The one assertion in this file that cannot be made through `src/`, and the reason the
        // import at the top exists. A `show` list that drops a name leaves every other test in this
        // file green while making the primitive unconstructible from outside the package — which is
        // how `StagnationDetector` was once lost: §3.2's "a separate control" was in the document
        // and in `src/`, and the barrel would not carry it.
        //
        // `identical` against the prefixed import rather than a name list, so a *missing* name is a
        // compile error here instead of a runtime comparison against a string that happened to match.
        expect(barrel.Deadline, same(Deadline));
        expect(barrel.CostBudget, same(CostBudget));
        expect(barrel.CostReserve, same(CostReserve));
        expect(barrel.StepBudget, same(StepBudget));
        expect(barrel.StagnationDetector, same(StagnationDetector));
        expect(barrel.RunControls, same(RunControls));
        expect(barrel.RunStopReason, same(RunStopReason));
        expect(barrel.Cancelled, same(Cancelled));
        expect(barrel.DeadlineExceeded, same(DeadlineExceeded));
        expect(barrel.BudgetExhausted, same(BudgetExhausted));
        expect(barrel.StepLimitReached, same(StepLimitReached));
        // `RunControls.cancel` is one of the four, so the token it is *typed* with has to come from
        // the same barrel — otherwise a caller holding only this package gets a member whose type it
        // cannot name, and §3.2's "re-exported, not a second implementation" is a claim about an
        // import the caller is not allowed to make. These are the protocol package's own types, and
        // `same` is what proves no core copy crept in behind the re-export.
        expect(barrel.CancelToken, same(CancelToken));
        expect(barrel.CancelReason, same(CancelReason));
      },
    );
  });

  group('the documents the code answers to', () {
    test('engine.md §3.1 is the caps the schema and the engine both hold', () {
      // Parsed, not restated: a copy of a table is a second table, and the two would agree until
      // somebody edited one of them. §3.1 says "The pre-split specification left these implicit.
      // They are now binding", so a number that changes there must turn this test red.
      final root = _repositoryRoot();
      final table = _documentedCounters(root);
      final byTerm = <String, String>{
        for (final row in table) _plain(row.$1): _plain(row.$2),
      };
      expect(byTerm.keys.toList(), <String>[
        'One step',
        'maxToolCallsPerStep',
        'maxToolCallsPerRun',
        'Stagnation signature',
        'Canonical args',
        'Stagnation window',
        'Reset',
      ], reason: '§3.1\'s table has these seven rows, in this order');

      // One step is one model turn. §3.1's first row, and the reason `StepBudget` has no member
      // taking a tool-call count.
      expect(byTerm['One step'], contains('model turn'));
      expect(byTerm['One step'], contains('once'));
      expect(byTerm['One step'], contains('tool calls'));

      // The per-step cap: default 8, hard cap 16, and the excess is recoverable rather than
      // terminal — `ToolOutcome.invalid(-32602)`, a code the taxonomy marks `feedsToModel`.
      final perStep = RegExp(r'Default (\d+), hard cap (\d+)')
          .firstMatch(byTerm['maxToolCallsPerStep']!);
      expect(
        perStep,
        isNotNull,
        reason:
            'the row still states a default and a hard cap: '
            '${byTerm['maxToolCallsPerStep']}',
      );
      final defaultPerStep = int.parse(perStep!.group(1)!);
      final capPerStep = int.parse(perStep.group(2)!);
      expect(defaultPerStep, 8);
      expect(capPerStep, 16);
      // Both numbers are shipped, and in two places that are checked against each other —
      // `Budgets.hardCapToolCallsPerStep` is "the schema's own cap … rather than a validator
      // magic number", and `toolCallsPerStepCap` is the schema's.
      expect(const Budgets().maxToolCallsPerStep, defaultPerStep);
      expect(Budgets.hardCapToolCallsPerStep, capPerStep);
      expect(toolCallsPerStepCap, capPerStep);
      expect(
        capPerStep,
        greaterThan(defaultPerStep),
        reason: 'a cap at the default would make the default unreachable',
      );
      expect(byTerm['maxToolCallsPerStep'], contains('-32602'));
      expect(
        JsonRpcErrorCode.invalidParams.feedsToModel,
        isTrue,
        reason:
            '-32602 is the code the row names, and it is correctable by design',
      );

      // The per-run cap: §3.1 says default 200 and configurable in `budgets`.
      final perRun = RegExp(r'Default (\d+)')
          .firstMatch(byTerm['maxToolCallsPerRun']!);
      expect(perRun, isNotNull, reason: 'the row still states a default');
      expect(int.parse(perRun!.group(1)!), 200);
      expect(byTerm['maxToolCallsPerRun'], contains('budgets'));
      // **The gap this file records rather than asserts away.** The default 200 exists in the
      // document and in the profile schema's example, and nowhere in `lib/`: `Budgets` takes it
      // as a nullable with no default and the validator reads the block with no fallback. So
      // §3.1's "Default 200" is currently applied by nothing, and a profile that omits the field
      // has no per-run tool-call limit at all. Asserted as the state of the tree, so the day a
      // default is added these two assertions say which of them changed.
      expect(
        const Budgets().maxToolCallsPerRun,
        isNull,
        reason: 'no shipped default: §3.1\'s 200 lives only in the document and the schema example',
      );
      final profileSource = File(
        '${root.path}/packages/alteri_one_core/lib/src/profile/profile.dart',
      ).readAsStringSync();
      expect(
        _code(profileSource),
        isNot(contains('= 200')),
        reason:
            'and no default was spelled as a literal beside `maxToolCallsPerRun`, which would be '
            'a third place the number lives',
      );
      expect(
        byTerm['maxToolCallsPerRun'],
        contains('configurable'),
        reason: 'the row says the cap is a configured value, not a constant of the engine',
      );

      // The signature, and the definition the detector takes as finished input. §3.1 names
      // SHA-256, which is why the vectors above are FIPS 180-4's and not a second hash to agree
      // with; and it makes canonicalisation somebody else's job, which is why `record` takes a
      // `String` and has no member that sorts keys.
      expect(byTerm['Stagnation signature'], contains('SHA-256'));
      expect(byTerm['Stagnation signature'], contains('toolId'));
      expect(byTerm['Stagnation signature'], contains('canonicalArgsJson'));
      expect(
        byTerm['Canonical args'],
        allOf(
          contains('sorted lexicographically'),
          contains('project-relative POSIX'),
        ),
      );
      expect(byTerm['Stagnation window'], contains('stagnationWindow'));
      expect(byTerm['Stagnation window'], contains('model turns'));
      // §3.1's Reset row is the sentence the detector's shape exists to keep, so it is parsed
      // rather than paraphrased: a successful outcome must **not** reset the window, and the row
      // is where a future edit would change that.
      expect(byTerm['Reset'], contains('different signature'));
      expect(byTerm['Reset'], contains('different tool'));
      expect(byTerm['Reset'], contains('terminal outcome'));
      expect(
        byTerm['Reset'],
        contains('does not reset'),
        reason: '§3.1: a successful ToolOutcome.ok does not reset it',
      );
      expect(
        byTerm['Reset'],
        contains('ToolOutcome.ok'),
        reason: 'and it names the outcome it is about',
      );

      // §5.1's tree rule, the other document this file parses. The criterion is "nested calls
      // never outlive parent deadline or budget" and §5.1 is where the specification says it.
      final engine = _prose(
        File('${root.path}/docs/architecture/engine.md').readAsStringSync(),
      );
      expect(
        engine,
        contains(
          'the effective child time is min(configured child deadline, parent remaining)',
        ),
        reason: '§5.1, the sentence the first test enforces',
      );
      expect(
        engine,
        contains('One CostBudget belongs to the whole tree'),
        reason: '§5.1: no child mints a budget',
      );
      expect(
        engine,
        contains(
          'A subagent is a child run with its own context window, its own Deadline',
        ),
        reason: '§5: the child deadline exists, and §5.1 is what bounds it',
      );
    });

    test('the §3 invariants this file enforces are still the ones the document states', () {
      // §3's bullets, checked as text rather than paraphrased, because the four that this file
      // is a test of are the four a later edit could quietly relax. `engine.md` §3.2 was added by
      // the same task and is what made the shapes checkable; §3 is what it interprets.
      // Read through `_prose`, so a rewrap of `engine.md` is not a failure here. Every one of
      // these sentences is wrapped across two or three physical lines in the document, and the
      // alternative — spelling the wrap in the expected string — is a test that breaks the first
      // time anybody runs prettier over the specification.
      final engine = _prose(
        File('${_repositoryRoot().path}/docs/architecture/engine.md')
            .readAsStringSync(),
      );
      expect(
        engine,
        contains('Infinity and "no timeout" are not accepted values'),
        reason: '§3: a deadline is always finite',
      );
      expect(
        engine,
        contains('Model, tool and subagent cannot raise the limit'),
        reason: '§3: the step limit is not raisable by the model, a tool or a subagent',
      );
      expect(
        engine,
        contains('a mandatory CostBudget with token and USD ceilings'),
        reason: '§3: both ceilings, and the budget is not optional',
      );
      expect(
        engine,
        contains(
          'Model, tool and subagent cannot bypass CostBudget, deadline, cancellation or policy '
          'through an internal API',
        ),
        reason:
            '§3: the claim the surface check above is the mechanical form of',
      );
      expect(
        engine,
        contains(
          'the terminal control outcomes -32030/-32031/-32032, which end the run',
        ),
        reason:
            '§3: the three codes are terminal, not outcomes the model corrects',
      );
      expect(
        engine,
        contains(
          'stagnationWindow times in a row is stagnation and stops the run',
        ),
        reason: '§3: the same tool, the same arguments, window times in a row',
      );
      // §3.1's one sentence this file's most subtle assertion rests on, quoted in full rather
      // than through §3.1's table, because the table row is one column of a reformat away.
      expect(
        engine,
        contains(
          'A successful ToolOutcome.ok does not reset it — the loop, not the outcome, is the '
          'signal',
        ),
        reason:
            '§3.1: the detector has no member taking an outcome precisely because of this '
            'sentence',
      );
    });
  });
}

// -------------------------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------------------------

/// The four controls of one run, with the ceilings this file needs rather than the ones §2 uses.
///
/// A helper and not an inline constructor because every test here needs the same shape, and a
/// test that builds its own is free to leave one control untripped by accident. [clock] is the
/// argument rather than constructed inside so the caller owns the one origin the run and its
/// children share — which is the property §3.2 is about, and the one a helper that made its own
/// clock could hide.
RunControls _controls(
  FakeClock clock, {
  Duration deadline = const Duration(minutes: 1),
  int maxTokens = 100000,
  double maxUsd = 100.0,
  int maxSteps = 40,
}) => RunControls(
  deadline: Deadline(clock: clock, startedAt: clock.now(), limit: deadline),
  budget: CostBudget(maxTokens: maxTokens, maxUsd: maxUsd),
  cancel: CancelToken(),
  steps: StepBudget(maxSteps: maxSteps),
);

/// A root [Deadline] of [limit] on [clock], started now.
///
/// [startedAt] is the wall clock's reading and is a record only — §3.2 says both comparisons come
/// from `monotonicNow` — so passing `clock.now()` here is what a composition root does.
Deadline _deadline(FakeClock clock, Duration limit) =>
    Deadline(clock: clock, startedAt: clock.now(), limit: limit);

/// The name of a stop, from an **exhaustive** switch with no `default`.
///
/// The claim is that `RunStopReason` is a closed union over the four controls, and the only check
/// that can hold that is a `switch` the compiler proves complete: a fifth variant breaks this line
/// rather than falling through a `default` nobody reads. It is also the reason this file needs no
/// reflection anywhere.
String _stopName(RunStopReason? reason) => switch (reason) {
  null => 'none',
  Cancelled() => 'Cancelled',
  DeadlineExceeded() => 'DeadlineExceeded',
  BudgetExhausted() => 'BudgetExhausted',
  StepLimitReached() => 'StepLimitReached',
};

/// The repository root, found by walking up from the working directory.
///
/// The acceptance command is `melos exec --scope=alteri_one_core -- dart test …` and melos runs it
/// *in the package*, so a test that opened `docs/architecture/engine.md` relative to the working
/// directory would work when run from the root by hand and fail in the one place it has to work.
/// A test that only passes in the way its author runs it is a test that will be skipped.
Directory _repositoryRoot() {
  const relative = 'docs/architecture/engine.md';
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

/// `docs/architecture/engine.md` §3.1's table as (term, definition) rows, in document order.
///
/// The table is bounded by its own header and by the first line after it that is not a row, so a
/// later §3.2 appended below it is not swept in. Only two columns are read and a row with any
/// other cell count ends the table: a parser that kept going would read the next table's rows as
/// this one's, and the comparison would then be against nothing.
List<(String, String)> _documentedCounters(Directory root) {
  final file = File('${root.path}/docs/architecture/engine.md');
  final rows = <(String, String)>[];
  var inSection = false;
  var inTable = false;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('### 3.1')) {
      inSection = true;
      continue;
    }
    if (inSection && line.startsWith('### ')) inSection = false;
    if (!inSection) continue;
    if (RegExp(r'^\|\s*Term\s*\|\s*Definition\s*\|').hasMatch(line)) {
      inTable = true;
      continue;
    }
    if (!inTable) continue;
    if (!line.trimLeft().startsWith('|')) break;
    if (line.trimLeft().startsWith('|---')) continue;
    final cells = line.split('|');
    // Two columns, so `| a | b |` splits into four elements: the two empty ends are part of the
    // split. The header match above has established that this table has two.
    if (cells.length != 4) break;
    rows.add((cells[1].trim(), cells[2].trim()));
  }
  if (rows.isEmpty) {
    throw StateError(
      'no rows parsed from ${file.path} §3.1; the table format changed, and a parser that reads '
      'nothing would compare an empty list against nothing and pass',
    );
  }
  return rows;
}

/// A markdown table cell with its emphasis and code markers removed.
///
/// `` `maxSteps` `` and **maxSteps** are the same term, and §3.1 writes `maxToolCallsPerStep` in
/// backticks while writing **Stagnation signature** in bold. Comparing the markers would make a
/// formatting change a failure and a change of meaning invisible.
String _plain(String cell) =>
    cell.replaceAll('`', '').replaceAll('**', '').trim();

/// [source] as one line of prose, with markdown emphasis removed.
///
/// **Markdown has no hard line breaks**, so a sentence in these documents is wrapped across
/// several physical lines and the wrap point is a formatting decision rather than part of the
/// claim. Every `contains` against a sentence below therefore runs against this, not against the
/// raw text: a substring that happens to cross a wrap would make a rewrap of `engine.md` a test
/// failure, and a check that fails on rewrap is a check somebody stops updating.
String _prose(String source) => source
    .replaceAll('`', '')
    .replaceAll('**', '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// `control.dart`'s source, read because the surface check reads members out of it.
String _controlSource(Directory root) {
  final file = File(
    '${root.path}/packages/alteri_one_core/lib/src/engine/control.dart',
  );
  if (!file.existsSync()) {
    throw StateError('${file.path} moved; the surface check reads it by path');
  }
  return file.readAsStringSync();
}

/// [source] with its full-line comments removed.
///
/// Only whole-line comments, and deliberately not `// …` inside a line: this file's checks are
/// about what the code *declares*, and `control.dart` discusses "no method raises it" and "no
/// `raise`" in prose on seven lines. Sweeping those in would fail on the documentation of the
/// property, which is the opposite of what a source check is for. Inline comments and string
/// literals are left in place because none of the patterns looked for here can appear inside one
/// without also being a declaration.
String _code(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// The extensions in `control.dart` that are declared on any of [types], sorted.
///
/// `_publicMembers` walks the class body, so an extension on one of these five is invisible to it —
/// and `final class` does not stop one, because an extension is resolved statically rather than
/// inherited. `extension CostBudgetX on CostBudget { void raise(int by) { … } }` therefore
/// compiles, is callable by anyone holding the type, and appeared nowhere in the member list: the
/// shortest path straight past §3's "model, tool and subagent cannot … bypass the ceiling through
/// an internal API". So the absence is asserted here, separately, against the same source.
///
/// Comments are stripped first for the reason `_code` gives — this file discusses the property in
/// prose, and a check that reads its own documentation is the opposite of a check.
List<String> _extensionsOn(Directory root, List<String> types) {
  final found = <String>[];
  for (final line in _code(_controlSource(root)).split('\n')) {
    final match = RegExp('^extension\\s+\\w*\\s*on\\s+(${types.join('|')})\\b')
        .firstMatch(line.trimLeft());
    if (match != null) found.add(match.group(1)!);
  }
  return found..sort();
}

/// The public members [type] declares in `control.dart`, sorted.
///
/// Parsed from the source rather than reflected on, for the reason `_declaredNamespaces` gives in
/// the registry contract test: the property under test is about the *text* a new method would have
/// to be added to. A getter and a method with the same name are one entry, which is right — the
/// claim is about what a caller can reach.
///
/// **What this does and does not buy.** It catches a member added inside the class body, and it
/// catches a rename or a removal. An earlier draft of this comment also claimed it would not see
/// "a member declared in a base class, an extension or an `export`", reading the first half of
/// that as a benefit — but a source parse has the same blind spot as reflection for the other two:
/// an `extension CostBudgetX on CostBudget { void raise(…) }` produced a **byte-identical** member
/// list here, and `final class` does not prevent an extension. So the extension half is a separate
/// check — `_extendsAnyOf` below — and this one is claimed no further than it is.
///
/// Exactly two-space indentation, which is `dart format`'s class-member indentation and therefore
/// a property of this repository rather than a guess: a member declared deeper is inside another
/// member's body and is not a member of the class. Private names are dropped, and so is the type's
/// own name, which is its constructor.
List<String> _publicMembers(String type, Directory root) {
  // **Line endings are normalised before anything here compares against a whole line.** There is
  // no `.gitattributes`, so a Windows checkout is CRLF: `split('\n')` then leaves every element
  // ending in `\r`, and the closing-brace search below asks for exact equality with `'}'`, which
  // never matches. Nothing raises when that happens — `end` runs to the end of the file, the slice
  // covers every class in control.dart, and the returned list silently becomes the *union* of all
  // their members: a check whose verdict is decided by lines nobody reading it would think it
  // looked at. `LineSplitter` splits on any terminator, so the parse below reads text on every
  // platform, while `split('\n')` elsewhere in this file survives only because nothing there
  // matches at the end of a line.
  final lines = const LineSplitter().convert(_controlSource(root));
  final declaration = RegExp('^(?:final |sealed |abstract )*class $type\\b');
  final start = lines.indexWhere(declaration.hasMatch);
  if (start < 0) {
    throw StateError(
      'no `class $type` declaration parsed from control.dart; a parser that reads nothing would '
      'compare an empty list against the expected members and fail with no reason',
    );
  }
  var end = start + 1;
  while (end < lines.length && lines[end] != '}') {
    end++;
  }
  // The lookahead is what stops a *local* from being read as a member: a declaration ends in
  // `(`, `=` or `;`, and a getter with a block body ends in `{` — a local is never followed by
  // `{` on the same line at two-space indentation, but `final int x = 1;` is, which is why the
  // `=` and `;` cases are here rather than only the parenthesised one. The two-space anchor is
  // what excludes a body statement, which `dart format` indents four.
  final pattern = RegExp(
    r'^ {2}(?! )'
    r'(?:@override\s+)?(?:static\s+|factory\s+|const\s+|final\s+|late\s+)*'
    r'([A-Za-z_][\w<>?,.\[\]]*)\s*(?:get\s+|set\s+)?([A-Za-z_]\w*)\s*(?=[(;=]|->\s*\{|\{)',
  );
  final members = <String>[];
  for (final line in lines.sublist(start + 1, end)) {
    final match = pattern.firstMatch(line);
    if (match == null) continue;
    final declared = match.group(1)!;
    final name = match.group(2)!;
    // **The constructor, which the two capture groups split in half.** `const RunControls({`
    // does not match the pattern as `RunControls` followed by a name, because a name has to
    // follow — so the regex backtracks and reports the *type* as `RunControl` and the *name* as
    // `s`. Joining the two groups back and comparing that with the class name is what
    // distinguishes a constructor from a real member, and it is why `RunControls` came back with
    // a member called `s` in an earlier draft of this file.
    //
    // `factory` is in the modifier alternation above for the same reason: without it the type
    // group reads `factory` and the name group reads the class's own name, so the join compares
    // `factoryDeadline` with `Deadline` and misses.
    //
    // **A named constructor carries a `.`**, so `const Deadline._({` joins back to `Deadline._`
    // and slips past a bare comparison with `Deadline`. Stripping the `.` first is what keeps the
    // private constructor a constructor: read as a member it contributed the *type* where the
    // first expected name was, which looks like a missing member rather than a parser that had
    // stopped recognising constructors.
    final joined = '$declared$name'.replaceFirst(
      RegExp(r'^([A-Za-z_]\w*)\..*$'),
      r'$1',
    );
    if (name.startsWith('_') || joined == type) continue;
    if (!members.contains(name)) members.add(name);
  }
  return members;
}
