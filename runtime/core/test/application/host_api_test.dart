// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

/// A [SecretStore] over a fixed map, counting reads.
final class _FakeSecretStore implements SecretStore {
  new(this._values);

  final Map<String, String> _values;
  int reads = 0;

  @override
  Future<String?> read(String name) async {
    reads++;
    return _values[name];
  }
}

/// A [HostFileSystem] over fixed maps, counting calls.
final class _FakeFileSystem implements HostFileSystem {
  new({Map<String, List<int>>? files})
    : _files = <String, List<int>>{...?files};

  final Map<String, List<int>> _files;
  int reads = 0;
  int writes = 0;

  @override
  Future<List<int>> read(String path) async {
    reads++;
    return _files[path] ?? const [];
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    writes++;
    _files[path] = bytes;
  }
}

/// A [HostNet] returning a fixed body, counting calls.
final class _FakeNet implements HostNet {
  new(this._body);

  final String _body;
  int calls = 0;
  final List<Uri> uris = [];

  @override
  Future<String> get(Uri uri) async {
    calls++;
    uris.add(uri);
    return _body;
  }
}

/// A [MemoryPort] returning fixed values, counting calls.
final class _FakeMemory implements MemoryPort {
  new({List<MemoryEntry>? recall}) : _recall = recall ?? const [];

  final List<MemoryEntry> _recall;
  int stores = 0;
  int recalls = 0;

  @override
  Future<MemoryId> store(
    MemoryDraft draft, {
    required RunId? runId,
    required bool untrusted,
  }) async {
    stores++;
    return MemoryId('mem-1');
  }

  @override
  Future<List<MemoryEntry>> recall(MemoryQuery query) async {
    recalls++;
    return _recall;
  }

  @override
  Future<void> forget(MemoryId id) async {}
}

/// A [JournalPort] that records denied host-calls and no-ops the rest.
final class _FakeJournal implements JournalPort {
  final List<String> hostCallDenials = [];

  @override
  Future<void> hostCallDenied(
    String extensionId,
    String operation,
    String permission,
  ) async {
    hostCallDenials.add('$extensionId $operation $permission');
  }

  @override
  Future<int> runStarted(RunId runId, String profile) async => 0;

  @override
  Future<int> runFinished(RunId runId, String state, String? result) async => 0;

  @override
  Future<int> started(RunId runId, String tool, Risk risk) async => 0;

  @override
  Future<int> modelStarted(RunId runId) async => 0;

  @override
  Future<void> denied(
    RunId runId,
    String tool,
    Risk risk,
    String reason,
  ) async {}

  @override
  Future<void> finished(
    RunId runId,
    int seq,
    InvocationStatus status,
    String? error,
  ) async {}

  @override
  Future<List<Invocation>> forRun(RunId runId) async => const [];

  @override
  Future<List<ModelCall>> modelCallsForRun(RunId runId) async => const [];

  @override
  Future<List<LifecycleRecord>> lifecycleAfter(int seq) async => const [];

  @override
  Future<int> approvalRequested(
    RunId runId,
    ApprovalId id,
    String tool,
    DateTime deadline,
  ) async => 0;

  @override
  Future<int> approvalResolved(
    ApprovalId id, {
    required bool granted,
    required String reason,
    DateTime? at,
  }) async => 0;

  @override
  Future<ApprovalRecord?> approvalById(ApprovalId id) async => null;

  @override
  Future<List<ApprovalRecord>> approvalsForRun(RunId runId) async => const [];
}

/// Builds a [HostApi] over fresh fakes, returned so a test can inspect them.
({
  HostApi api,
  _FakeSecretStore secrets,
  _FakeFileSystem files,
  _FakeNet net,
  _FakeMemory memory,
  _FakeJournal journal,
})
_build({
  Set<String> permissions = const {},
  String extensionId = 'weather',
  Map<String, String>? secretValues,
  Map<String, List<int>>? files,
  String netBody = 'ok',
}) {
  final secrets = _FakeSecretStore(secretValues ?? const {});
  final file = _FakeFileSystem(files: files);
  final net = _FakeNet(netBody);
  final memory = _FakeMemory();
  final journal = _FakeJournal();
  final api = HostApi(
    permissions: EffectivePermissions(permissions),
    extensionId: extensionId,
    secrets: secrets,
    files: file,
    net: net,
    memory: memory,
    journal: journal,
  );
  return (
    api: api,
    secrets: secrets,
    files: file,
    net: net,
    memory: memory,
    journal: journal,
  );
}

void main() {
  test(
    'secret is allowed with host.secret:<name> and reaches the store',
    () async {
      final h = _build(
        permissions: {'host.secret:API_KEY'},
        secretValues: {'API_KEY': 's3cr3t'},
      );

      final value = await h.api.secret('API_KEY');

      expect(value, 's3cr3t');
      expect(h.secrets.reads, 1);
      expect(h.journal.hostCallDenials, isEmpty);
    },
  );

  test('secret is denied without the permission and is journalled', () async {
    final h = _build(
      permissions: const {'host.secret:OTHER'},
      secretValues: {'API_KEY': 's3cr3t'},
    );

    await expectLater(
      h.api.secret('API_KEY'),
      throwsA(isA<HostCallForbidden>()),
    );
    expect(h.secrets.reads, 0, reason: 'the effect must not be reached');
    expect(h.journal.hostCallDenials, ['weather secret host.secret:API_KEY']);
  });

  test(
    'secret value is returned only to the caller, never a tool value',
    () async {
      final h = _build(
        permissions: {'host.secret:API_KEY'},
        secretValues: {'API_KEY': 's3cr3t'},
      );

      final value = await h.api.secret('API_KEY');

      // The secret op returns the raw value to the extension; it is not wrapped
      // in any model-visible structure.
      expect(value, isA<String>());
      expect(value, 's3cr3t');
    },
  );

  test('readFile is allowed with host.fs:<path>', () async {
    final h = _build(
      permissions: {'host.fs:/data/a.txt'},
      files: {
        '/data/a.txt': [1, 2, 3],
      },
    );

    final bytes = await h.api.readFile('/data/a.txt');

    expect(bytes, [1, 2, 3]);
    expect(h.files.reads, 1);
    expect(h.journal.hostCallDenials, isEmpty);
  });

  test('readFile is denied for another path and is journalled', () async {
    final h = _build(permissions: const {'host.fs:/data/a.txt'});

    await expectLater(
      h.api.readFile('/etc/passwd'),
      throwsA(isA<HostCallForbidden>()),
    );
    expect(h.files.reads, 0);
    expect(h.journal.hostCallDenials, ['weather readFile host.fs:/etc/passwd']);
  });

  test('writeFile is allowed with host.fs:<path>', () async {
    final h = _build(permissions: {'host.fs:/data/out.txt'});

    await h.api.writeFile('/data/out.txt', [9, 8]);

    expect(h.files.writes, 1);
    expect(h.journal.hostCallDenials, isEmpty);
  });

  test(
    'writeFile is denied without the permission and is journalled',
    () async {
      final h = _build();

      await expectLater(
        h.api.writeFile('/data/out.txt', [9, 8]),
        throwsA(isA<HostCallForbidden>()),
      );
      expect(h.files.writes, 0);
      expect(h.journal.hostCallDenials, [
        'weather writeFile host.fs:/data/out.txt',
      ]);
    },
  );

  test('memoryStore is allowed with host.memory.write', () async {
    final h = _build(permissions: {'host.memory.write'});

    final id = await h.api.memoryStore(
      MemoryDraft.plain('a fact'),
      runId: null,
      untrusted: false,
    );

    expect(id, MemoryId('mem-1'));
    expect(h.memory.stores, 1);
    expect(h.journal.hostCallDenials, isEmpty);
  });

  test(
    'memoryStore is denied without host.memory.write and is journalled',
    () async {
      final h = _build(permissions: const {'host.memory.read'});

      await expectLater(
        h.api.memoryStore(
          MemoryDraft.plain('a fact'),
          runId: null,
          untrusted: false,
        ),
        throwsA(isA<HostCallForbidden>()),
      );
      expect(h.memory.stores, 0);
      expect(h.journal.hostCallDenials, [
        'weather memoryStore host.memory.write',
      ]);
    },
  );

  test('memoryRecall is allowed with host.memory.read', () async {
    final h = _build(permissions: {'host.memory.read'});

    final entries = await h.api.memoryRecall(MemoryQuery.text('fact'));

    expect(entries, isEmpty);
    expect(h.memory.recalls, 1);
    expect(h.journal.hostCallDenials, isEmpty);
  });

  test(
    'memoryRecall is denied without host.memory.read and is journalled',
    () async {
      final h = _build(permissions: const {'host.memory.write'});

      await expectLater(
        h.api.memoryRecall(MemoryQuery.text('fact')),
        throwsA(isA<HostCallForbidden>()),
      );
      expect(h.memory.recalls, 0);
      expect(h.journal.hostCallDenials, [
        'weather memoryRecall host.memory.read',
      ]);
    },
  );

  test('netGet is allowed for the exact host', () async {
    final h = _build(
      permissions: {'net:api.open-meteo.com'},
      netBody: 'forecast',
    );

    final body = await h.api.netGet(Uri.parse('https://api.open-meteo.com/v1'));

    expect(body, 'forecast');
    expect(h.net.calls, 1);
    expect(h.journal.hostCallDenials, isEmpty);
  });

  test('netGet is denied for a subdomain of an allowed host', () async {
    final h = _build(permissions: const {'net:api.open-meteo.com'});

    await expectLater(
      h.api.netGet(Uri.parse('https://evil.api.open-meteo.com/v1')),
      throwsA(isA<HostCallForbidden>()),
    );
    expect(h.net.calls, 0);
    expect(h.journal.hostCallDenials, [
      'weather netGet net:evil.api.open-meteo.com',
    ]);
  });

  test('netGet is denied for a different host', () async {
    final h = _build(permissions: const {'net:api.open-meteo.com'});

    await expectLater(
      h.api.netGet(Uri.parse('https://example.com/v1')),
      throwsA(isA<HostCallForbidden>()),
    );
    expect(h.net.calls, 0);
    expect(h.journal.hostCallDenials, ['weather netGet net:example.com']);
  });

  test('EffectivePermissions.grants is exact-match only', () {
    final permissions = EffectivePermissions(const {'net:api.example.com'});
    expect(permissions.grants('net:api.example.com'), isTrue);
    expect(permissions.grants('net:sub.api.example.com'), isFalse);
    expect(permissions.grants('net:other.example.com'), isFalse);
  });
}
