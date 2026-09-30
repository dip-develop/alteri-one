/// Off-isolate work, and the channel an isolate hop runs over.
///
/// [architecture/protocol.md] §7 lists `ipc` as "in-process exchange, isolate-to-isolate,
/// parent/child channels" and §7.1 names this port as the thing that implements
/// [TransportChannel]: *"The channel is a port, and the platform decides which one.
/// `TransportChannel` is the smallest thing an isolate, a socket or an in-memory queue can sit
/// behind, and `alteri_one_platform`'s `Concurrency` port implements it."* This file is that
/// sentence, and it is the only reason `alteri_one_protocol` can stay free of `dart:isolate`.
///
/// ## Why `Object` and not `SendPort`
///
/// [ConcurrencyPeer.receiveHandle] is an [Object] and [ConcurrencyPeer.send] takes one, rather than
/// naming `dart:isolate`'s [SendPort] and [ReceivePort]. Naming them would put `dart:isolate` in a
/// file that has to compile for the browser, which is the entire rule
/// [architecture/overview.md] §3 exists to state. It would also make the port unimplementable
/// without a second isolate, when the point of a port is that a test and a same-isolate Tier 1 call
/// can both sit behind it.
///
/// So the peer is **opaque and structural**: a `Map` is already sendable between isolates with no
/// send-port pair in it, and one is enough for `dart:isolate`. The handle stays an [Object] rather
/// than becoming a `Map<String, Object?>` because a declared shape would be a second, wrong
/// description of the wire, and this package is not where that is specified.
///
/// ## Why there is a [maxParallelism] and no pool
///
/// [architecture/build-and-release.md] §7.1 says `Isolate.run` is used *"where the `Concurrency`
/// abstraction genuinely matches the platform"*, and [run] is that shape: a closure in, a future
/// out, the platform choosing what runs it where.
///
/// What is deliberately **not** here is a pool. A bounded pool with a queue, a worker count and a
/// scheduling policy is a second scheduler, and [architecture/protocol.md] §7.1's third decision is
/// that the in-process link has no scheduler at all — no timer, no microtask, nothing a loaded
/// machine can reorder. An engine whose CPU work is dispatched through a pool has its determinism
/// bounded by the pool's queue order, and a contract test that interleaves two runs would stop
/// being reproducible. [maxParallelism] is reported so a caller can *choose* not to spawn more work
/// than the host can run; nothing here acts on it.
///
/// ## A channel this port hands out can refuse
///
/// [channel]'s result obeys [TransportChannel.write] returning `bool`, and that is not a formality
/// — [architecture/protocol.md] §7.1 spells out why: *"A port's write reports whether it took the
/// bytes, because §2.2's rule is that a write refused for space is backpressure and not an error."*
/// A channel here that could only accept would make the bound in `FrameOutbox` unreachable and
/// `backpressured` a value no caller could ever see, which is exactly what happened to the first
/// version of that transport.
///
/// [architecture/protocol.md]: ../../../../docs/architecture/protocol.md
/// [architecture/build-and-release.md]: ../../../../docs/architecture/build-and-release.md
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
library;

import 'dart:async';

import 'package:alteri_one_protocol/alteri_one_protocol.dart';

import 'clock.dart';

/// A closure that produces a value, on whatever unit of work the platform chooses.
///
/// Deliberately not a top-level function reference plus its arguments: that is what a
/// `compute`-style API takes, it cannot close over anything, and every use site then has to decide
/// what to do with captured state. A closure is what `Isolate.run` takes, so the native
/// implementation is a direct expression of the platform and a fake runs it in-line.
typedef Computation<R> = FutureOr<R> Function();

/// An opaque, sendable endpoint for another unit of work.
///
/// No platform type appears in this interface and none may be named by an implementation that
/// wants to stay web-compilable — see this file's documentation. The two members are what
/// `dart:isolate`'s `SendPort` pair *is*, expressed without the import.
abstract interface class ConcurrencyPeer {
  /// Something this isolate can receive on.
  ///
  /// Opaque to everything except the implementation that produced it. On the native
  /// implementation it is a `SendPort`, which is sendable and therefore usable as the peer in
  /// `Isolate.run` — which is how `channel` below works with no other mechanism.
  Object get receiveHandle;

  /// Hands [message] to the peer.
  ///
  /// May throw if the peer is gone; a `dart:io` send to a dead port does exactly that, and it is
  /// reported as a channel error rather than swallowed.
  void send(Object? message);
}

/// Off-isolate execution, and the channels an isolate hop runs over.
///
/// Injected into the engine rather than reached for, for the same reason every other port here is:
/// [architecture/overview.md] §4 puts knowledge of implementations in the composition root, and
/// [process/testing-strategy.md] §3 makes a deterministic double mandatory for anything that
/// touches concurrency.
abstract interface class Concurrency {
  /// How many units of work this host can run at once.
  ///
  /// **Reported, not enforced.** See this file's documentation: a pool would be a second
  /// scheduler, and §7.1's determinism rules forbid one. A caller reads this to decide whether to
  /// offer more work, and `doctor` reports it.
  int get maxParallelism;

  /// The clock the host schedules against.
  ///
  /// Held rather than reached for, because a unit of work that takes two seconds to be scheduled is
  /// time the caller is charged for and must be able to measure. It is also what makes this port
  /// testable: a fake clock and a fake `Concurrency` answer [run] in-line and instantly, and a real
  /// host with a fake clock still schedules on the real one, so a deadline assertion has to be made
  /// against [AlteriOneClock.monotonicNow] rather than a stopwatch.
  AlteriOneClock get clock;

  /// Runs [computation] on a unit of work other than the caller's.
  ///
  /// Returns a future for the value, and propagates whatever the closure threw or returned as an
  /// error — a `Future`, not a sync call, because the native implementation cannot start an isolate
  /// synchronously and an interface that pretended otherwise would be unimplementable over
  /// `dart:isolate`.
  ///
  /// Errors are **not** wrapped. An unwrapped error is what lets a caller distinguish "the
  /// computation failed" from "the host could not run it", which is the difference between a bug in
  /// the work and a refusal by the platform, and a wrapper type would erase it.
  ///
  /// [debugName] appears in host diagnostics; it carries no scheduling meaning.
  Future<R> run<R>(Computation<R> computation, {String? debugName});

  /// A byte channel to [peer].
  ///
  /// Returns a [TransportChannel], not a bespoke channel type, and that is the requirement rather
  /// than a convenience: [architecture/protocol.md] §7.1 needs the *same* framed transport over an
  /// isolate hop as over an in-memory pair, so a second channel interface would mean a second
  /// transport above it and a second description of where a frame ends.
  ///
  /// The channel is this end only. Nothing here closes the peer's end, and [TransportChannel.close]
  /// signals the peer rather than waiting for it — the rule task `0.8` states for the stdio adapter
  /// applies here for the same reason: a close is what a `finally` block calls, and a teardown that
  /// blocks hangs the CLI on Ctrl-C.
  TransportChannel channel(ConcurrencyPeer peer);
}
