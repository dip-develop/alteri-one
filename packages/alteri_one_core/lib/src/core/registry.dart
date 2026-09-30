/// The registry: one owner per namespace, one owner per tool id, and both refusals rather
/// than tie-breaks.
///
/// [docs/architecture/overview.md] §5 states the invariant this file exists to hold: "**the
/// owner of a namespace is exactly one package**, and it is either a `tools/` package or a
/// `plugins/` package — never two, never an app and never the core. A tool implementation ships
/// inside its one owning package, so every tool id has one implementation and one namespace
/// owner. Adding a tool in an existing namespace, or a plugin providing a new namespace,
/// requires no change to the core. Registering two owners for the same namespace is a
/// **bind-time failure with no implicit priority**."
///
/// ## Why there is no `import` of any extension package
///
/// [docs/architecture/overview.md] §4 makes `apps/cli` the composition root and says the
/// registry is "generated from the resolved dependency graph". A *generated* registry is a
/// build-time artefact; what lands in the core is the **shape** it has, and the instances come
/// from the composition root as values. That is why [ExtensionUnit] carries a
/// [MethodHandler] rather than a plugin type: `alteri_one_core` cannot import
/// `alteri_one_memory` — `overview.md` §3 and the workspace contract test both say so — so a
/// registry that named plugin types would fix the extension set at compile time, which is the
/// one thing the §3 rule exists to prevent.
///
/// The consequence, and it is the point rather than a limitation: adding a plugin adds a
/// `register` call in `apps/cli` and nothing anywhere else. No core file changes, no switch
/// grows a case, and the workspace contract test's "no product library imports an extension
/// package" keeps holding.
///
/// ## Why the two built-ins are seeded rather than checked against a list
///
/// `core` and `$` are reserved ([docs/concepts.md] §2.1) and the core owns them. Rather than a
/// `reserved.contains(...)` check on every registration, the registry is **seeded** with the
/// engine and the control plane as its first two owners — so an extension claiming `core` is a
/// second owner for one namespace and reports as exactly that, `extension.duplicate_id`. One rule
/// for one situation; see [namespace] for why the alternative was a second rule for a case the
/// first already covers.
library;

import '../profile/diagnostic.dart';
import 'method_call.dart';
import 'namespace.dart';

/// One bound extension unit: a namespace, the tool ids it owns, and the handler that answers
/// for it.
///
/// **A value, not a plugin.** [docs/extensibility/plugins.md] §1's `AlteriOnePlugin` also
/// carries a `PluginManifest` and a lifecycle, and neither of those types exists yet — the
/// manifest is task `0.29` and the lifecycle is `plugins.md` §2's `discover → validate → bind →
/// initialize → start → serve → stop`, which is a *host* decision made once by the composition
/// root. Binding only what dispatch needs is what keeps the registry from becoming a second
/// place that starts a unit.
final class ExtensionUnit {
  /// Creates a unit owning [namespace], answering through [handler], exposing [toolIds].
  const ExtensionUnit({
    required this.namespace,
    required this.handler,
    this.toolIds = const <String>[],
    this.moduleVersion,
  });

  /// The namespace this unit is the owner of. Unique across the registry.
  final MethodNamespace namespace;

  /// What answers a call routed here.
  final MethodHandler handler;

  /// The tool ids this unit implements, e.g. `['fs.read', 'fs.write']`.
  ///
  /// A tool's id and its namespace are related — `fs.read` dispatches under `fs` — and the
  /// registry **checks** that rather than deriving it, because a unit that implements
  /// `web.search` while owning the `fs` namespace is a manifest that disagrees with its tool
  /// list, and `config.manifest_drift` is the right answer for that. Deriving the namespace from
  /// the tool ids instead would make the two impossible to disagree and would lose the
  /// diagnosis.
  final List<String> toolIds;

  /// The unit's own module version, for the transcript.
  ///
  /// A `String` and not a semver type because [ProtoVersion] in the protocol package versions the
  /// *session*, and a unit's `moduleVersion` is validated against `alterione.yaml` →
  /// `api.extension` by task `0.29`. Parsing it here would be a second, looser parse of a value
  /// one task owns.
  final String? moduleVersion;

  @override
  String toString() =>
      'ExtensionUnit($namespace, ${toolIds.length} tools'
      '${moduleVersion == null ? '' : ', v$moduleVersion'})';
}

/// A registration the registry refused, and why.
///
/// Returned rather than thrown, and the reason is [docs/architecture/overview.md] §5's
/// "bind-time failure": a bind reports **every** fault it finds and then fails, rather than
/// stopping at the first. A composition root wiring twenty units wants to know about all four
/// collisions in one run, and a `register` that threw would have told it about one and thrown
/// away the other three.
final class RegistrationFailure {
  /// Creates a failure.
  const RegistrationFailure({
    required this.code,
    required this.path,
    required this.error,
    this.hint,
  });

  /// The code, from `error-codes.md` §3.
  final DiagnosticCode code;

  /// Where the fault is, as a path the caller can print. A dotted id path (`fs.read`) rather
  /// than a file location, because a registration is not a document — the composition root is
  /// code, and the fault is in what the code said.
  final String path;

  /// What is wrong, in one clause.
  final String error;

  /// What to do about it.
  final String? hint;

  @override
  String toString() => '${code.code} at $path: $error';
}

/// What one `register` call did.
final class RegistrationOutcome {
  /// Creates an outcome.
  const RegistrationOutcome({required this.accepted, this.failure});

  /// Whether the unit was bound.
  final bool accepted;

  /// Why it was not, or null when it was.
  final RegistrationFailure? failure;

  /// The failure as a `ConfigDiagnostic`, so a composition root can hand it to the same
  /// reporting path a configuration fault uses.
  ///
  /// The bridge is here rather than at every call site because the two are the same kind of
  /// thing: a bind-time refusal with a code and a path. `doctor --validate-config` prints
  /// diagnostics, and a registry fault that cannot be printed is a fault the operator debugs
  /// from a stack trace.
  ConfigDiagnostic? get diagnostic {
    final failure = this.failure;
    if (failure == null) return null;
    return ConfigDiagnostic(
      code: failure.code,
      path: failure.path,
      values: <String, Object?>{
        'field': failure.path,
        'expected': failure.hint ?? failure.error,
      },
    );
  }

  @override
  String toString() => accepted
      ? 'RegistrationOutcome(accepted)'
      : 'RegistrationOutcome($failure)';
}

/// The bound extension units, and the two ownership rules that hold them.
///
/// **Not mutable after construction.** [ExtensionRegistry.build] takes every unit at once and
/// returns a registry, so a registry cannot change underneath a dispatcher that is routing calls
/// into it. `plugins.md` §2's lifecycle has `bind` before `start` and nothing after it that
/// rebinds, so a registry that could grow mid-run would model a phase the lifecycle does not
/// have.
final class ExtensionRegistry {
  ExtensionRegistry._(this._byNamespace, this._tools, this._namespaces);

  /// Builds a registry from [units], refusing every collision it finds.
  ///
  /// [seeded] are the built-in owners the extension units must not collide with — the engine's
  /// `core` and the control plane's `$`. They are validated with the same rule as the
  /// extensions, so a caller that forgets to seed them gets the same answer for `core` as for a
  /// duplicated plugin, rather than a second code for the same situation.
  ///
  /// Returns both the registry and **every** refusal, in registration order. A caller that wants
  /// to fail on the first can; `plugins.md` §2's `validate` step is a phase, and a phase that
  /// sees one fault at a time is a phase run many times.
  static (ExtensionRegistry?, List<RegistrationFailure>) build(
    List<ExtensionUnit> units, {
    List<ExtensionUnit> seeded = const <ExtensionUnit>[],
  }) {
    final byNamespace = <MethodNamespace, ExtensionUnit>{};
    final tools = <String, MethodNamespace>{};
    final failures = <RegistrationFailure>[];

    for (final unit in <ExtensionUnit>[...seeded, ...units]) {
      final failure = _check(unit, byNamespace, tools);
      if (failure != null) {
        failures.add(failure);
        continue;
      }
      byNamespace[unit.namespace] = unit;
      for (final tool in unit.toolIds) {
        tools[tool] = unit.namespace;
      }
    }

    if (failures.isNotEmpty)
      return (null, List<RegistrationFailure>.unmodifiable(failures));
    return (
      ExtensionRegistry._(
        Map<MethodNamespace, ExtensionUnit>.unmodifiable(byNamespace),
        Map<String, MethodNamespace>.unmodifiable(tools),
        byNamespace.keys.toSet(),
      ),
      const <RegistrationFailure>[],
    );
  }

  /// The check, shared by the seeded and the extension units.
  ///
  /// Three rules, in the order that gives the most useful diagnostic when more than one is
  /// broken:
  ///
  /// 1. **The namespace is already owned.** `extension.duplicate_id` — the code
  ///    `error-codes.md` §3 defines for "two units claim one id". A reserved namespace is
  ///    already owned because [build] seeded it, so `core` and `$` need no rule of their own.
  /// 2. **A tool id is already owned.** The same code: `plugins.md` §1 says "a tool id has
  ///    exactly one owner and never two", and a duplicate tool id is a duplicate id. Note the
  ///    owner is compared by *namespace*, not by unit: a duplicate tool id inside one unit is
  ///    also a fault, and it is the same fault.
  /// 3. **A tool id does not sit in another unit's namespace.** `config.manifest_drift` — a
  ///    manifest that parses and disagrees with the graph. `web.search` implemented by the unit
  ///    owning `fs` dispatches nowhere: `concepts.md` §2 says the dotted prefix is the dispatch
  ///    key, so the call would be routed to `web` and no owner would answer.
  static RegistrationFailure? _check(
    ExtensionUnit unit,
    Map<MethodNamespace, ExtensionUnit> byNamespace,
    Map<String, MethodNamespace> tools,
  ) {
    final existing = byNamespace[unit.namespace];
    if (existing != null) {
      final reserved = unit.namespace.isReserved
          ? ' It is reserved by ${unit.namespace} and owned by the built-in, not by a package.'
          : '';
      return RegistrationFailure(
        code: ExtensionDiagnosticCode.extensionDuplicateId,
        path: unit.namespace.value,
        error: 'two owners claim this namespace',
        hint:
            'a namespace has exactly one owner and there is no implicit priority; '
            '${existing.namespace} is already bound.$reserved',
      );
    }

    // **The unit's own duplicates, checked before anything is inserted.** `build` fills
    // [tools] only after this function returns null, so a duplicate *within* one unit is invisible
    // to the loop below — `tools['fs.read']` is still absent when the same unit's second
    // `fs.read` is examined. The result was a unit declaring `['fs.read', 'fs.write', 'fs.read']`
    // binding successfully, keeping the first and silently discarding the third, in a registry
    // whose own comment said the opposite.
    //
    // It is the same fault, and that is the point: `overview.md` §5's rule is that a tool id has
    // one implementation, and a unit listing one twice has two entries for one implementation.
    // Checking it here rather than by pre-filling [tools] keeps "a refused unit reserves
    // nothing" true, which a registry holding partially-applied state would not.
    final seenHere = <String>{};
    for (final tool in unit.toolIds) {
      if (seenHere.add(tool)) continue;
      return RegistrationFailure(
        code: ExtensionDiagnosticCode.extensionDuplicateId,
        path: tool,
        error: 'listed twice by one unit',
        hint:
            'a tool id has exactly one implementation and one owner; $tool appears more than '
            'once in this unit, so which of the two is the implementation is a question the '
            'registry cannot answer',
      );
    }

    for (final tool in unit.toolIds) {
      final owner = tools[tool];
      if (owner != null) {
        return RegistrationFailure(
          code: ExtensionDiagnosticCode.extensionDuplicateId,
          path: tool,
          error: 'two owners claim this tool id',
          hint:
              'a tool id has exactly one implementation and one owner; $tool is already bound '
              'to $owner',
        );
      }
      if (!toolIdGrammar.hasMatch(tool)) {
        return RegistrationFailure(
          code: ConfigDiagnosticCode.configInvalidSchema,
          path: tool,
          error: 'not a tool id',
          hint: 'a tool id is ${toolIdGrammar.pattern}, e.g. fs.read',
        );
      }
      final key = MethodNamespace.dispatchKeyOf(tool);
      if (key != null && key != unit.namespace) {
        return RegistrationFailure(
          code: ConfigDiagnosticCode.configManifestDrift,
          path: tool,
          error: 'declared in a namespace this unit does not own',
          hint:
              'the dotted prefix is the dispatch key, so $tool is routed to $key; this unit '
              'owns ${unit.namespace}',
        );
      }
    }
    return null;
  }

  /// The units by the namespace they own, including the seeded built-ins.
  final Map<MethodNamespace, ExtensionUnit> _byNamespace;

  /// Every tool id, mapped to the namespace that dispatches it.
  final Map<String, MethodNamespace> _tools;

  /// The namespaces bound, for the diagnostics that enumerate the known set.
  final Set<MethodNamespace> _namespaces;

  /// The namespaces this registry answers for, sorted.
  ///
  /// Sorted rather than in registration order because a diagnostic that lists the known
  /// namespaces has to be stable: two runs that registered the same units in a different order
  /// must produce the same message, or the transcript digest differs for no reason.
  List<MethodNamespace> get namespaces => _namespaces.toList()..sort();

  /// The unit owning [namespace], or null when nothing is bound for it.
  ExtensionUnit? operator [](MethodNamespace namespace) =>
      _byNamespace[namespace];

  /// The owner of the namespace [toolId] dispatches to, or null when no unit owns it.
  ///
  /// The answer is the **namespace**, not the unit, on purpose: `tools.md` §1.2 filters on tool
  /// ids long before anything is registered, and a caller asking "who dispatches this" wants the
  /// routing key. [handlerForTool] is the other question.
  MethodNamespace? namespaceForTool(String toolId) => _tools[toolId];

  /// The handler that answers a call for [toolId], or null.
  MethodHandler? handlerForTool(String toolId) {
    final namespace = _tools[toolId];
    return namespace == null ? null : _byNamespace[namespace]?.handler;
  }

  /// Whether [namespace] is bound.
  bool owns(MethodNamespace namespace) => _byNamespace.containsKey(namespace);

  /// Whether [toolId] is implemented.
  bool implementsTool(String toolId) => _tools.containsKey(toolId);

  /// The tool ids, sorted.
  List<String> get toolIds => _tools.keys.toList()..sort();

  /// A description of what is bound, for a diagnostic's `{expected}` placeholder.
  ///
  /// Sorted, for the same reason [namespaces] is: a message that differs between two runs that
  /// registered the same units makes the runs indistinguishable in a transcript and not in fact.
  String get summary => namespaces.map((n) => n.value).join(', ');

  @override
  String toString() =>
      'ExtensionRegistry(${namespaces.length} namespaces, ${_tools.length} tools)';
}
