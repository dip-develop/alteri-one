# Injections

**Status: Accepted**

An **injection** is a deterministic transform applied to the context on the way to the
model. It is the only extension surface with **no authority at all**: it receives a
labelled context and returns a labelled context, and nothing it does can change policy,
budget, deadline, the capability registry or what the model is allowed to call. That is
the whole reason it is a separate noun rather than a plugin kind — see
[ADR-0014](../decisions/0014-extension-subprojects.md).

Tier 0 skill packs are injections: an injection may be data or code, and the two are
specified in the same document because they share every guarantee that matters.

## 1. The contract

```dart
/// Tier 1: an injection implemented in Dart and linked into the AOT build.
abstract interface class Injection {
  InjectionDescriptor get descriptor;

  /// Pure with respect to everything except [context]: no I/O, no network,
  /// no tool call, no capability request, no policy consultation.
  Future<LabeledContent<List<ContextFragment>>> apply(
    InjectionRequest request, {
    required Deadline deadline,
    required CancelToken cancel,
  });

  /// Optional. Called once at bind time with a read-only view of the product.
  void configure(InjectionConfig config) {}
}
```

```dart
final class InjectionDescriptor {
  const InjectionDescriptor({
    required this.id,          // ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$
    required this.stage,       // ContextStage
    required this.order,       // int, lower runs earlier within a stage
    required this.tier,        // InjectionTier.data | InjectionTier.trusted
    this.affectsTrust = false,// see §3
    this.maxInputTokens = 0,   // 0 = bounded by the run deadline only
  });
}
```

A Tier 0 injection implements no interface: it is a directory of validated data, applied
by the host. It is listed here because it obeys the same rules, not because it shares an
ABI with the Tier 1 form.

### 1.1 The stages

| Stage | Runs | Typical injection |
|---|---|---|
| `assemble` | before a turn is built: selects what goes into the context | `skill` — binds a pack for the run |
| `transform` | on the assembled context, in order | `translate` — locale shaping |
| `summarise` | when `triggerTokens` is reached | `compress` — deterministic compaction |

The stage is declared, not inferred, because an injection that runs before the context
exists and one that runs after compression have different failure modes and different
places to record what they did.

### 1.2 Order is deterministic and declared

Within a stage, injections run in ascending `order`, then by `id` ascending. The order is
part of the product's observable behaviour, so it is recorded in the transcript: a run
whose context changed must be explainable without guessing which injection ran first.

Two injections at the same `order` in the same stage is a bind-time conflict with no
implicit priority — the same rule that governs two plugins claiming one namespace.

## 2. The manifest

```yaml
apiVersion: alteri.one/v1
kind: InjectionManifest
name: example.translate          # ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$
moduleVersion: 1.0.0
extensionApi: ">=1.0.0 <2.0.0"   # must be inside alterione.yaml → api.extension
tier: trusted                    # trusted (Tier 1) | data (Tier 0)
stage: transform
order: 30
affectsTrust: false              # see §3
```

A `tools:` list, a `requires:` list or any capability field is **rejected by the
validator** for this `kind`. There is no field in which a capability request could be
written, which is the point: the guarantee is structural rather than a runtime check that
somebody could forget to call.

## 3. Authority: none, and how that is kept true

| Guarantee | Mechanism |
|---|---|
| Cannot obtain a capability | no field to request one; the runtime it receives carries none |
| Cannot register or call a tool | `AlteriOneRuntime` exposes no registry or dispatch to it |
| Cannot alter policy, budget or deadline | it receives no policy handle; a deadline is a read-only bound, not a raisable one |
| Cannot read a secret | no environment, no filesystem, no network, no credential path |
| Cannot raise trust | output is relabelled by the host from the ingress point, and `affectsTrust: true` is refused outright |
| Cannot persist to trusted memory | memory writes go through a typed port that requires a granted capability it is never given |

`affectsTrust: false` is therefore not a declaration to be trusted — it is a check. An
injection that returns content derived from `userStated` or `systemGenerated` fragments is
downgraded to the lowest provenance present in its input, so a translate or compress pass
cannot launder untrusted content into a trusted instruction. This is the property the
"one unit, one authority" rule in [concepts.md](../concepts.md#12-one-unit-one-authority)
exists to guarantee.

Content an injection produces is appended with its own boundary marker and its original
label. It is never spliced into a system prompt, and an injection cannot write to the
persona, the profile instructions or the tool schemas.

## 4. Lifecycle

```text
discover → validate → bind → configure → apply → (repeat per turn)
```

1. **Discover.** From the compiled registry generated from the resolved dependency graph
   (Tier 1) or from a digest-verified directory in the install root (Tier 0).
2. **Validate.** `extensionApi` against `alterione.yaml` → `api.extension`, stage and order
   against the configured set, and the Tier 0 digest for data.
3. **Bind.** One id per injection; a duplicate id or a conflicting order stops the bind.
4. **Configure.** Read-only product view. No capability is granted here, ever.
5. **Apply.** Per turn, per stage, in declared order, inside the run deadline.

An injection that throws is isolated to its own contribution: the transform is skipped,
the original fragments are kept, and `injection.failed` is recorded with the reason. A Tier
1 injection cannot take the run down, and it cannot prevent the run either — failing to
compress is not a reason to refuse a task.

## 5. Built-in injections in v1

| Injection | Subproject | Stage | Tier | Purpose |
|---|---|---|---|---|
| `alteri_one_injection_skill` | `injections/skill/` | `assemble` | 0 (data) and 1 | Skill packs: validate, bind to a profile, apply as `skillContent/untrusted` |
| `alteri_one_injection_compress` | `injections/compress/` | `summarise` | 1 | Token-triggered compaction, preserving facts with their original provenance |
| `alteri_one_injection_translate` | `injections/translate/` | `transform` | 1 | Locale shaping of the context through the `intl` catalogue |

The skill pack format, the Agent Skills mapping and the pack loader are specified in
[skill-packs.md](skill-packs.md). The MCP Skills extension, when implemented, arrives as a
Tier 0 injection with identical guarantees — never as a trusted path.

## 6. Adding an injection

1. `dart run apps/cli/bin/main.dart init injection example.translate` scaffolds the
   package, the `InjectionManifest`, contract tests and the `alterione.yaml` entry.
2. Implement `Injection` and its descriptor. Do not add a `requires:` field; the
   validator will reject the manifest and that is the intended first failure.
3. Add the dependency to `pubspec.yaml`, the entry to `alterione.yaml`, then
   `dart pub get && melos run generate`.
4. Contract-test: the label of every returned fragment, the refusal path for
   `affectsTrust: true`, order determinism, and that a throwing injection is skipped
   rather than fatal.

An injection is removed by removing the dependency and the entry and rebuilding. There is
no runtime removal for compiled code, for the reason in
[workspace-layout.md](../architecture/workspace-layout.md#31-pubspecyaml-resolves-alterioneyaml-declares);
a Tier 0 data injection is removed by deleting its directory.
