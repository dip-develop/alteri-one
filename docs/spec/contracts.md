# 10. Contracts and schemas

> Part of the AlteriOne specification, version 1.3. Reading map: `docs/spec/index.md`.

## 10.1 Principles

- Everything that crosses a process boundary is JSON. Inside a process, the domain works with Dart types.
- Schemas are described once as Dart classes, and schemantic generates the JSON Schema.
- Picoschema is not used anywhere: not for configuration, manifests, the protocol, or prompts.
- DTOs and domain entities are separate. Mapping happens at the boundary in `interface/`.
- The exception is `ToolSpec` and `Risk`. They form the public language of extensions and are used directly.

## 10.2 schemantic

A model is described by an abstract class with a `$` prefix. schemantic generates the class, `toJson`, `fromJson`, `jsonSchema()`, and an asynchronous `validate`.

```dart
// alteri_one_contracts/lib/src/run.dart
@Schema()
abstract class $Run {
  String get id;
  String get profile;
  RunState get state;
  @Field(name: 'session_id')
  String? get sessionId;
  String? get result;
  DateTime get createdAt;
}
```

[VERIFY: exact annotation syntax (`@Schema`, `@Field`, `defaultValue`, `enumValues`) and support for the `@AnyOf` discriminator, checked against the schemantic 0.2.x documentation in spike T2.]

Known limitations:
- `@Field(name:)` is set on every field. There is no automatic snake_case conversion, so field names are written explicitly.
- Sealed hierarchies with a `type` discriminator are not described by schemantic. `AgentEvent` is written by hand.
- For `Map<String, Object?>` without a fixed schema (for example, a tool's `inputSchema`), a raw JSON Schema is used as a `Map`.
- `additionalProperties: false` is not documented for generated classes. The configuration loader rejects unknown keys (section 14).
- Dart enums: use `enumValues` on a string field, or a custom serializer. Verified in spike T2.
- `validate` is asynchronous and is called with `await`.

## 10.3 Protocol DTOs

Generated with schemantic:
- `ServerInfo`, `PairRequest`, `PairResponse`.
- `RunCreateRequest`, `Run`, `Invocation` (without tool input and output).
- `ApprovalRequest`, `ApprovalDecision`.
- `MemoryEntry`, `MemoryDraft`, `MemoryQuery`.
- `ExtensionManifest`, `ExtensionProvides`, `ToolSpec` (with the `untrustedOutput` field, default `true`).
- `ApiError { code, message, details }`.

Error codes are constants in `alteri_one_contracts`. A client must treat an unknown code as a generic error. Error messages never contain secrets or fragments of prompts.

| Code | HTTP status | Meaning |
|---|---|---|
| `run_not_found` | 404 | run not found |
| `approval_conflict` | 409 | a decision has already been made |
| `forbidden` | 403 | insufficient scope |
| `unauthorized` | 401 | missing or invalid token |
| `shutting_down` | 503 | the daemon is stopping |
| `invalid_request` | 400 | validation failed |
| `extension_unavailable` | 503 | the extension is unloaded or has crashed |
| `budget_exceeded` | 429 | budget limit reached |

## 10.4 Protocol events (hand-written)

```dart
sealed class AgentEvent {
  const AgentEvent({required this.at, this.seq});
  final DateTime at;
  final int? seq;   // null for ephemeral events

  factory AgentEvent.fromJson(Map<String, Object?> json) => switch (json['type']) {
        'run.started' => RunStarted.fromJson(json),
        'run.delta' => RunDelta.fromJson(json),
        'run.finished' => RunFinished.fromJson(json),
        'approval.requested' => ApprovalRequested.fromJson(json),
        'approval.resolved' => ApprovalResolved.fromJson(json),
        'extension.state' => ExtensionStateChanged.fromJson(json),
        'server.shutdown' => ServerShutdown(at: DateTime.parse(json['at']! as String)),
        _ => UnknownEvent.fromJson(json),   // a new type does not break an older client
      };
}

final class RunStarted extends AgentEvent {
  const RunStarted({required super.at, super.seq, required this.runId, required this.profile});
  final String runId;
  final String profile;
  factory RunStarted.fromJson(Map<String, Object?> j) => RunStarted(
        at: DateTime.parse(j['at']! as String),
        seq: j['seq'] as int?,
        runId: j['run_id']! as String,
        profile: j['profile']! as String,
      );
}
// The remaining subtypes follow the same pattern.
```

Subtypes are in the same library (a requirement of `sealed`). They use classic constructors.

Rules: `run.delta` is ephemeral (`seq == null`) and is not replayed. Every other event that changes state is written to the journal first and receives a `seq`.

## 10.5 Extension manifest (YAML)

```yaml
id: weather
version: 1.2.0
contract: 2.0.0          # alteri_one_contracts version the extension was built against
sdk: 3.13.0              # exact Dart SDK version used to build the snapshot
target: linux-x64
provides:
  tools: [forecast]
  triggers: [daily_digest]
  channels: []
  context: []
  memory_backend: false
  skills: []
permissions:
  - net:api.open-meteo.com
  - host.memory.write    # only if the extension writes memory
sha256: "..."            # hash of the .aot snapshot
signature: "..."         # Ed25519 over the canonical JSON without the signature field
```

The manifest is validated against the JSON Schema generated by schemantic. The signature is computed over the canonical JSON produced from the parsed YAML.
