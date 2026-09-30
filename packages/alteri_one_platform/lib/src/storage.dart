/// The storage boundary: collections, typed values, migrations and the single-writer lock.
///
/// [architecture/overview.md] §3.1 is the rule this port exists to hold:
///
/// > `alteri_one_memory` MUST NOT import `hive_ce` or `dart:io`. The `HiveCeStorage` adapter is
/// > implemented in `alteri_one_platform` against `StoragePort`; memory owns domain records and
/// > repositories only.
///
/// It is a resolution of a contradiction in the pre-split specification, and the direction of the
/// rule matters more than the package named in it. `alteri_one_memory` holds
/// [MemoryRecord](https://github.com/dip-develop/alteri-one), `VectorIndex` and the transcript
/// store — domain types whose shape is a product decision. `hive_ce` is a fork without official
/// endorsement ([decisions/risks.md]), and a domain package that imports it makes that choice
/// permanent and makes a browser build impossible. So the dependency points from the platform into
/// the domain's *shape* and never back.
///
/// ## The value type is bytes with a tag, and that is the compromise in this port
///
/// [StorageValue] carries a `Uint8List` and a `String` tag and nothing else. Not `Map<String,
/// dynamic>`, and not a `hive_ce` frame.
///
/// - A `Map<String, dynamic>` would push the storage engine's schema into the port, so migrating
///   the engine becomes a change to every record type — which is what [ADR-0004] is trying to avoid.
/// - A `hive_ce` frame would make the port a re-export of the engine, and [ADR-0004] says the point
///   is that it is not.
/// - Opaque bytes with a tag let `hive_ce_generator` (task `1.1`) own the codec, keep the *port*
///   free of it, and leave the tag as the place a future engine migration can branch.
///
/// The cost is that a record cannot be queried by field through this port, and that is
/// deliberate: [ADR-0004] records that `hive_ce` is a KV store with no approximate
/// nearest-neighbour index, that vector recall sits behind a separate `VectorIndex`, and that
/// **"a brute-force scan over Hive is never presented as vector search"**. A port with a query
/// language is how that prohibition gets broken without anyone deciding to break it.
///
/// ## The lock is in the port, not beside it
///
/// [ADR-0004] lists as forbidden: *two processes writing one profile state directory
/// concurrently*. Hive is not safe for concurrent writers, and the second process does not fail
/// cleanly — it corrupts, or it silently overwrites. So the lock is [StoragePort.acquireWriteLock]
/// and a [StoragePort] that can be opened without one is a port whose implementations are all
/// unsafe.
///
/// It is **bounded** and it **refuses**. `acquireWriteLock` completes with a [StorageLock] that
/// says whether it was granted, rather than throwing on a timeout and rather than waiting for ever:
/// a second CLI invocation on a profile the first one holds has to be able to say *"another
/// process is using this profile"* and exit, which is a message. Blocking for ever makes the
/// failure a hang, and a hang is what a stale lock file from a killed process already looks like.
///
/// Whether a lock file that outlived its process is a lock is decided by the implementation and its
/// timeout, never here: this port states the requirement and the shape of the answer.
///
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [ADR-0004]: ../../../../docs/decisions/0004-storage-hive-ce.md
/// [decisions/risks.md]: ../../../../docs/decisions/risks.md
library;

import 'dart:async';
import 'dart:typed_data';

/// A stored value: opaque bytes under a type tag.
///
/// The tag is the storage-level type name — `MemoryRecord.fact`, `TranscriptRecord`, and so on —
/// and it is what `hive_ce_generator`'s adapter registers against in task `1.1`. It is **not** a
/// schema version: that is [StorageCollection.schemaVersion], which migrates all of a
/// collection's values at once.
final class StorageValue {
  /// Creates a value.
  ///
  /// [bytes] is retained by reference, deliberately. A store reads a value out of a file and
  /// hands it straight to a repository; copying it first would double the peak memory of every
  /// recall for no benefit, and the port's contract is that a [StorageValue] is immutable —
  /// [bytes] is the caller's list and mutating it corrupts what was stored.
  StorageValue({required this.typeTag, required this.bytes});

  /// The storage-level type name.
  final String typeTag;

  /// The encoded record.
  final Uint8List bytes;

  /// The value as a list, for an implementation that stores something else.
  List<int> get asList => bytes;

  @override
  bool operator ==(Object other) =>
      other is StorageValue &&
      other.typeTag == typeTag &&
      _sameBytes(other.bytes, bytes);

  @override
  int get hashCode => Object.hash(typeTag, bytes.length);

  @override
  String toString() => 'StorageValue($typeTag, ${bytes.length} bytes)';
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// One key/value collection inside a profile's state directory.
///
/// Named rather than typed: [architecture/memory.md] §2's records are a sealed hierarchy, and
/// `hive_ce` boxes are untyped, so the mapping between them is task `1.1`'s work rather than
/// something this interface can promise. What the interface *can* promise is the lifecycle — open,
/// read, write, delete, enumerate, close — and the migration hook, which is the part that is easy
/// to forget and impossible to add later: a collection opened at a version its store has not
/// reached is the one case where a silent default would destroy a user's memory.
abstract interface class StorageCollection {
  /// The collection's name — one of `sessions`, `messages`, `facts`, `episodes`, `preferences`,
  /// `artifacts` for the memory store.
  String get name;

  /// The schema version this collection is opened at.
  int get schemaVersion;

  /// The value at [key], or null.
  Future<StorageValue?> read(String key);

  /// Stores [value] at [key], replacing whatever was there.
  Future<void> write(String key, StorageValue value);

  /// Removes [key] and reports whether it was there.
  ///
  /// A `bool` because "forget this fact" has to be able to tell a caller that the record was
  /// already gone, and task `1.3`'s delete/export/forget needs to report that honestly rather than
  /// count a removal that removed nothing.
  Future<bool> delete(String key);

  /// Every key, optionally restricted to those starting with [prefix].
  ///
  /// [prefix] rather than a range or a pattern, because [ADR-0004]'s one-word reason for choosing
  /// a KV store was that a JSON file per record has no cheap prefix scan. A port whose enumeration
  /// cannot ask that question does not keep that promise.
  Future<List<String>> keys({String? prefix});

  /// Every value, in unspecified order.
  ///
  /// Separate from [keys] so a caller that wants to enumerate *without* reading bodies — a
  /// retention sweep deciding what is large, an export listing its contents — does not pull every
  /// record out of the store to throw most of it away.
  Future<List<StorageValue>> values({String? prefix});

  /// Removes everything, and reports how many values went.
  Future<int> clear();

  /// Closes the collection and releases its handle.
  Future<void> close();
}

/// The result of asking for the single-writer lock.
///
/// A value and not a throw, for the reason [acquireWriteLock] documents: a refusal here is a
/// message a second CLI invocation prints, not an exception.
///
/// **A `final` class with an [onRelease] hook**, which is how an implementation supplies the real
/// work — removing a lock file, dropping a lease — without inheriting. The alternative was an
/// overridable [release] on a non-final class, and a subclass that overrides a method has to
/// remember to call `super`, so a lock whose release silently stopped completing its future is one
/// careless override away; a callback the base class invokes cannot be forgotten. It also means a
/// test double can model a lock it genuinely holds without becoming a subclass, which is what
/// [_InMemoryStorage] in the contract test does.
final class StorageLock {
  /// A lock that was granted.
  ///
  /// [onRelease] is invoked once, by the first [release], and is what makes this a lock rather than a
  /// flag: the implementation's real work happens here while the base class still owns the
  /// idempotence and the [released] future.
  StorageLock.granted({
    required this.token,
    required this.heldSince,
    this.onRelease,
  }) : isHeldByAnotherProcess = false,
       holderDescription = null,
       _releaseRequested = false;

  /// A lock that was **not** granted within the timeout.
  ///
  /// [token] is still assigned and [heldSince] is still the monotonic time of the attempt, because
  /// a caller logging a refusal wants both; neither one is a claim on the lock, and [release] on a
  /// refusal is a no-op that completes [released] rather than touching anything.
  StorageLock.refused({
    required this.token,
    required this.heldSince,
    required this.holderDescription,
  }) : onRelease = null,
       isHeldByAnotherProcess = true,
       _releaseRequested = false;

  /// The opaque token identifying this acquisition.
  ///
  /// Passed to [release] so a caller cannot release a lock it does not hold. It is not a file path
  /// and never should be: the value exists to make releasing checkable, and a string a caller
  /// could also treat as a path would give it a second, wrong use.
  final String token;

  final Completer<void> _released = Completer<void>();
  bool _releaseRequested;

  /// Completes when this lock is released.
  ///
  /// The lock is held until it completes, so a caller that needs "when may I close" has a future
  /// rather than a flag it has to poll. It never throws: a lock that failed to release has still
  /// stopped being held as far as the process is concerned, and the next acquisition is what proves
  /// it.
  Future<void> get released => _released.future;

  /// What releasing this lock does, or null when there is nothing to do.
  ///
  /// Never called on a refusal: a lock that was never granted has nothing to release, and calling the
  /// holder's hook would be a second process dropping the first one's lock — which is the exact
  /// failure [StoragePort.acquireWriteLock] exists to prevent.
  final void Function()? onRelease;

  /// Monotonic time at which the lock was granted, from the injected clock.
  ///
  /// A monotonic instant and not a wall clock, for the same reason [AlteriOneClock] separates
  /// them: a lock file records how long the holder has had it, and that must not move backwards.
  final Duration heldSince;

  /// Whether the lock is held by another process, so this one was refused.
  ///
  /// The single field a caller branches on. `isHeldByAnotherProcess == false` means the lock is
  /// this caller's to release; the combination of the two is exhaustive, which is why [token] and
  /// [released] are present on a refusal too — a refused lock has a token that was never granted,
  /// and a caller that released it would be releasing somebody else's lock.
  final bool isHeldByAnotherProcess;

  /// Who holds it, when [isHeldByAnotherProcess] is true — a process id and whatever the holder
  /// chose to record.
  ///
  /// Null for a granted lock. Not an empty string: "we do not know" and "the holder recorded
  /// nothing" are different, and a message that prints one of them as the other sends an operator
  /// looking for a process that was never there.
  final String? holderDescription;

  /// Releases the lock: runs [onRelease] once, then completes [released]. Idempotent.
  ///
  /// Never throws. [onRelease] is the only thing that can fail — it touches a filesystem — and a
  /// lock that failed to release has *still* stopped being held as far as this process is concerned,
  /// so a throw here would replace the failure the caller was already handling with one about the
  /// teardown. The next acquisition is what proves whether the release worked.
  Future<void> release() {
    if (_releaseRequested) return released;
    _releaseRequested = true;
    if (isHeldByAnotherProcess) {
      // A refusal owns nothing. Completing rather than throwing keeps a caller's `finally` honest:
      // it released what it was handed and there was nothing to do.
      if (!_released.isCompleted) _released.complete();
      return released;
    }
    try {
      onRelease?.call();
    } on Object {
      // Reported by the next `acquireWriteLock` succeeding or not, which is the only observation
      // that says anything. Swallowed here on purpose and stated rather than hidden.
    }
    if (!_released.isCompleted) _released.complete();
    return released;
  }

  @override
  String toString() =>
      'StorageLock(${isHeldByAnotherProcess ? 'refused, held by ' : 'granted, '}heldSince: '
      '$heldSince)';
}

/// The storage boundary, and the single-writer lock that guards it.
///
/// `dart:io`-free so `alteri_one_memory` can hold a reference to one without taking a filesystem
/// dependency — which is the whole point of [architecture/overview.md] §3.1.
abstract interface class StoragePort {
  /// Asks for the single-writer lock over this profile's state directory.
  ///
  /// [timeout] bounds the wait, and the answer is a [StorageLock] that says whether it was
  /// granted. Refusing rather than throwing or waiting for ever is the design: [ADR-0004] lists
  /// two concurrent writers as *forbidden*, so the second process's job is to report that and stop,
  /// and a hang would be indistinguishable from the stale-lock case the timeout has to clear.
  ///
  /// **Calling this is not optional.** An implementation may refuse to open anything until the lock
  /// has been granted, and a [StoragePort] reachable without one is a port every one of whose
  /// implementations is unsafe — so the lock is on the interface rather than in a comment on it.
  Future<StorageLock> acquireWriteLock(
    String namespace, {
    Duration timeout = const Duration(seconds: 10),
  });

  /// Opens [name] at [schemaVersion], migrating it if the store is behind.
  ///
  /// [schemaVersion] is what the *caller* believes the collection is at, and the store is what it
  /// actually holds; the difference is the migration, and it runs under the lock
  /// [acquireWriteLock] granted. Opening at a version the store has never reached is an error and
  /// not a migration: that is a caller ahead of its own data, and treating it as a migration would
  /// write a version number into a store whose contents are from the future.
  Future<StorageCollection> openCollection(
    String name, {
    required int schemaVersion,
  });

  /// The schema version [name] is stored at, or null if it has never been opened.
  ///
  /// Separate from [openCollection] so a caller can find out what it is dealing with before it
  /// opens — which is how `doctor` reports a version mismatch without opening anything.
  Future<int?> storedVersion(String name);

  /// Closes every open collection and releases the port's own resources.
  ///
  /// Idempotent, for the reason [HttpClientPort.close] is.
  Future<void> close();
}
