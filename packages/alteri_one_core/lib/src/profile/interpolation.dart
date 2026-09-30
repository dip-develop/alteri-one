/// `${ENV_VAR}` substitution — the one substitution, and the one thing it is not.
///
/// [architecture/configuration.md] §1 and [reference/config-schema.md] §6 are the
/// specification, and they are short enough to state here in full because every line of it is a
/// decision:
///
/// - Substitution happens **after parsing and before validation**, and **only inside a string
///   scalar**. A key is never a variable reference and a number is never a template, so the
///   substituted document is still a document and the validator sees real values.
/// - **Command substitution, backticks and arbitrary expressions are rejected.** Not "not
///   supported": *rejected*, with a diagnostic. A user who writes `$(cat ~/.ssh/id_rsa)`
///   learns that this is a configuration format and not a shell, and the difference between the
///   two designs is that a shell is one they already know how to be careful with.
/// - **A missing variable is `config.missing_env`,** never an empty string. An empty string in
///   `apiKeyEnv` would produce a provider that authenticates as nobody.
/// - **Secrets come from the environment only.** A secret field names its variable and never
///   carries its value — see [nameOnlyFields] and the reason it exists.
///
/// ## What a substitution records, and why
///
/// [InterpolatedString.substitutions] is not bookkeeping. It is what makes "redacted in
/// diagnostics" structural: the catalogue's redaction keys on the *placeholder name*
/// (`lib/src/l10n/catalogue.dart`), and the interpolator is what guarantees a value that came
/// out of the environment only ever lands under a name the catalogue redacts. A caller that
/// forgets to say so has put a secret in a `{field}`-named placeholder, which is a mistake in
/// the validator rather than a hole in the design.
///
/// ## Why there is no default-value form
///
/// `${VAR:-fallback}` and `${VAR:default}` are rejected, and the reason is not conservatism.
/// A default for a secret is a *literal secret in a file*, which is the thing §1 exists to
/// prevent, and a default for a non-secret is a value the user believes comes from the
/// environment and does not. A second syntax to learn is the smaller cost; a resolved value
/// whose provenance nobody can state is the larger one.
///
/// [architecture/configuration.md]: ../../../../docs/architecture/configuration.md
/// [reference/config-schema.md]: ../../../../docs/reference/config-schema.md
library;

/// Reads one environment variable, returning null when it is not set.
///
/// A function rather than a port, and the reason is reachability rather than taste: the core
/// imports no `dart:io` and so has no `Platform.environment`, while `alteri_one_platform`
/// declares six ports and none of them is the environment —
/// `architecture/overview.md` §3's table is the constraint, and adding a seventh port for one
/// lookup is a larger change than a one-line adapter in the composition root. The composition
/// root passes `Platform.environment::[]`; a test passes a map.
typedef EnvironmentLookup = String? Function(String name);

/// A value read from the environment, and where it was used.
final class EnvSubstitution {
  /// Creates a record of one substitution.
  const EnvSubstitution({required this.name, required this.path});

  /// The variable's name, e.g. `OPENAI_API_KEY`. Never its value — this type is what a
  /// diagnostic may print.
  final String name;

  /// The JSON/YAML path of the scalar it was substituted into, e.g. `model.providers[1].baseURL`.
  final String path;

  @override
  String toString() => '${name}@$path';
}

/// A string after substitution, with a record of what came from where.
final class InterpolatedString {
  /// Creates an interpolated value.
  const InterpolatedString(
    this.value, [
    this.substitutions = const <EnvSubstitution>[],
  ]);

  /// The value, with every reference resolved.
  final String value;

  /// What was substituted, in document order.
  final List<EnvSubstitution> substitutions;

  /// Whether anything came from the environment.
  bool get hasSubstitutions => substitutions.isNotEmpty;

  @override
  String toString() =>
      'InterpolatedString($value, ${substitutions.length} substitutions)';
}

/// A reference this format refuses.
///
/// Thrown by [interpolate] and turned into a [DiagnosticCode] by the document layer, which is
/// the only place that knows the file and the position. Splitting it that way is what lets the
/// substitution grammar be tested on its own — a table of inputs and outputs — instead of
/// through a whole document.
final class InterpolationFailure implements Exception {
  /// Creates a failure with a [reason] that names what was wrong and, where there is one, the
  /// [variable] the reference tried to name.
  const InterpolationFailure(this.reason, {this.variable});

  /// What is wrong, in one clause. Never carries an environment value.
  final String reason;

  /// The variable the reference named, when it named one legibly. Null for a form that does not
  /// name a variable at all, such as a command substitution.
  final String? variable;

  @override
  String toString() => variable == null ? reason : '$reason: ${variable!}'; // ignore: unnecessary_string_interpolations
}

/// Substitutes every `${NAME}` in [value] from [lookup].
///
/// Returns the value unchanged when it contains no reference, and that early return is not just
/// an optimisation: a document with no references must not depend on the environment at all, so
/// a run on a machine with an unusual environment produces the same profile.
///
/// Throws [InterpolationFailure] for a form this format does not accept. The forms are
/// enumerated rather than left to a regexp's silence:
///
/// | Input | Why it is refused |
/// |---|---|
/// | `$(cmd)` | command substitution — this is a configuration format, not a shell |
/// | ``$`cmd` `` | the same, in the other shell's spelling |
/// | `${VAR:-x}`, `${VAR:x}` | a default is a literal value in a file, which is what §1 forbids |
/// | `${#VAR}` | length expansion, which has no meaning here |
/// | `${!VAR}` | indirection: a variable naming a variable is an unbounded read |
/// | `${A${B}}` | nesting, which makes the set of things a document can read open-ended |
/// | `${}` | no name |
/// | `${` with no `}` | unterminated, and left alone it would read as a reference to whatever the author meant |
/// | `${9BAD}` | not a variable name |
///
/// **A bare backtick pair is deliberately *not* in that table.** `` `whoami` `` on its own is
/// seven characters of text: nothing in this product evaluates a scalar, so no substitution is
/// happening and there is nothing to refuse. It is also ordinary content — `persona.bio`
/// explaining that commands go in `backticks`, a tool description quoting a shell line — and
/// refusing it would make those fields unwritable to fix a fear that does not apply.
///
/// What §1 and §6 refuse is *command substitution*, and in a string a reader might mistake for
/// a shell that is `$(…)` or `` $`…` ``. Both begin with a `$`, both are refused, and the
/// distinction is the leading `$` rather than the presence of a backtick anywhere in the value.
/// The table is written in terms of the **form**, and the earlier version of this comment listed
/// `` `cmd` `` as refused — which was wrong in the direction that matters, because it described
/// a refusal the code does not make.
InterpolatedString interpolate(
  String value,
  EnvironmentLookup lookup, {
  String path = r'$',
}) {
  if (!value.contains(r'$')) return InterpolatedString(value);

  final out = StringBuffer();
  final substitutions = <EnvSubstitution>[];
  var index = 0;

  while (index < value.length) {
    final character = value[index];

    if (character != r'$') {
      out.write(character);
      index++;
      continue;
    }

    // `$$` is an escaped dollar. It is not in the specification, and it is here because without
    // it there is no way to write a literal `${` in a profile — `persona.bio` describing a
    // shell snippet is ordinary, and a format that cannot represent it is a format somebody
    // works around by removing the example.
    if (index + 1 < value.length && value[index + 1] == r'$') {
      out.write(r'$');
      index += 2;
      continue;
    }

    final next = index + 1 < value.length ? value[index + 1] : '';

    if (next == '(') {
      throw InterpolationFailure(
        'command substitution is not accepted in a configuration value',
      );
    }
    if (next == '`') {
      throw const InterpolationFailure(
        'command substitution is not accepted in a configuration value',
      );
    }
    if (next == '{') {
      final close = value.indexOf('}', index + 2);
      if (close == -1) {
        throw const InterpolationFailure(
          r'unterminated ${ reference; write $$ for a literal dollar sign',
        );
      }
      final name = value.substring(index + 2, close);
      if (name.contains(r'$')) {
        throw InterpolationFailure(
          'a nested reference is not accepted',
          variable: name,
        );
      }
      if (!_name.hasMatch(name)) {
        throw InterpolationFailure(
          'not an environment variable name',
          variable: name,
        );
      }
      final resolved = lookup(name);
      if (resolved == null) {
        throw InterpolationFailure(
          'environment variable is not set',
          variable: name,
        );
      }
      out.write(resolved);
      substitutions.add(EnvSubstitution(name: name, path: path));
      index = close + 1;
      continue;
    }

    // A `$` that is not a reference at all — `5$` in prose, a bare dollar — is literal. Being
    // strict here would refuse a persona bio for no reason a user could act on.
    out.write(character);
    index++;
  }

  return InterpolatedString(out.toString(), substitutions);
}

/// Fields that carry the **name** of a secret and must never carry its value.
///
/// `apiKeyEnv:` is the case [architecture/configuration.md] §1 names: "configuration names the
/// variable". A `${OPENAI_API_KEY}` in that field would be a *resolved* secret written into a
/// resolved configuration document, which is the file that gets copied between machines, read
/// into bug reports and printed by `doctor`. So the field is a list of names and the
/// substitution is refused there, whatever the variable is set to.
///
/// It is a list rather than a flag on a field because the rule is about the **field's meaning**,
/// and a flag would have to be remembered at every field that ever holds a secret — which is the
/// convention this whole file exists to replace. Adding a name here is reviewed, which is why the
/// contract test asserts each one is a known field of its document.
const nameOnlyFields = <String>{'apiKeyEnv'};

/// A variable name, as an environment defines one.
final RegExp _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// A [EnvironmentLookup] over a fixed map.
///
/// Library code rather than a test helper, for the reason `FakeProvider` and `FakeClock` are:
/// [architecture/memory.md] §4 and [apps/cli.md] §5 need a *scripted environment* from another
/// package's test, and a `test/` directory is not on another package's resolution path. A
/// missing variable answers null, which is the same answer a real unset variable gives — a
/// double that disagreed with the port on that case would make `config.missing_env` untestable.
EnvironmentLookup environmentLookupOf(Map<String, String> environment) =>
    (String name) => environment[name];
