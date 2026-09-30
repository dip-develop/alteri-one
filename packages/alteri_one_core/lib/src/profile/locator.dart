/// Where configuration is read from, as paths — computed here, opened by the caller.
///
/// [architecture/workspace-layout.md] §4 is the specification: four levels, and for each of them
/// the file that carries it. This file turns that table into a list of [ConfigLocation]s in
/// priority order, which is what makes "the profile is assembled from these three files, in
/// this order" a value a test can assert rather than a sequence of `exists` calls scattered
/// through a composition root.
///
/// ## Why it returns paths and does not read them
///
/// `alteri_one_core` imports no `dart:io`, so it cannot open a file even if it wanted to. The
/// arrangement is deliberate: [Paths] knows *which directories exist* — it is the port, and
/// `exists` is one of its members — while *reading a document* is the composition root's, which
/// is the only package with `dart:io`. So this file answers "where", the CLI answers "what", and
/// neither has a copy of the other's answer.
///
/// ## The project level is found by walking up
///
/// §4: "The project level is the nearest ancestor directory containing an `alterione.yaml`". The
/// walk is here rather than in the CLI because the rule is about configuration precedence and
/// not about the CLI, and because a second implementation of "nearest ancestor" is a second
/// answer to whether a project file applies — which is the question a user debugging an
/// unexpected profile needs answered correctly once.
///
/// ## What is not a path
///
/// Levels 0 and 3 have no file: 0 is Dart objects in the binary and 3 is command-line flags.
/// They are in [ConfigLocation.kind] as [ConfigDocumentKind.builtin] and
/// [ConfigDocumentKind.cliOverride] rather than absent, so a caller iterating the plan can see
/// the whole precedence table rather than inferring the ends from its middle.
///
/// [architecture/workspace-layout.md]: ../../../../docs/architecture/workspace-layout.md
library;

import 'package:alteri_one_platform/alteri_one_platform.dart';

import 'document.dart';

/// Which kind of configuration a location carries.
///
/// Not the same axis as [ConfigKind] — that is what a document *declares*, this is where one
/// comes from and in what role.
enum ConfigDocumentKind {
  /// A `kind: Profile` file under `profiles/`.
  profileFile,

  /// The `profile:` block of an `alterione.yaml`.
  ///
  /// The same document, at a different role: `config-schema.md` §1.4 says the block's remaining
  /// keys "are ordinary `kind: Profile` fields applied as a local override at precedence 2". A
  /// separate kind because the file is a manifest with a profile inside it, and validating the
  /// whole file as a profile would report `runtime` and `api` as unknown fields.
  manifestProfileBlock,

  /// Dart objects compiled into the binary.
  builtin,

  /// Command-line flags.
  cliOverride,
}

/// One place configuration comes from.
final class ConfigLocation {
  /// Creates a location.
  const ConfigLocation({
    required this.level,
    required this.kind,
    required this.label,
    this.path,
    this.subPath,
    this.required = false,
  });

  /// Which of the four levels this belongs to.
  final ConfigLevel level;

  /// What the document at this location is.
  final ConfigDocumentKind kind;

  /// How a diagnostic names this location.
  ///
  /// The file's path rather than a `file:` URI, because a diagnostic is shown to a person and
  /// `file:///home/…` in a message is noise. The composition root produces it from the same
  /// [Uri] it hands to `File`, so the two cannot disagree about which file this is.
  final String label;

  /// The file to read, or null for [ConfigDocumentKind.builtin] and
  /// [ConfigDocumentKind.cliOverride], which have none.
  final Uri? path;

  /// The key inside the file holding the document, for
  /// [ConfigDocumentKind.manifestProfileBlock] — always `profile`.
  final String? subPath;

  /// Whether the run cannot start without this one.
  ///
  /// True for the user profile and false for the project manifest: §5 of
  /// `config-schema.md` makes the `profile` block optional, and a plan that marked it required
  /// would make every project without a developer profile unresolvable.
  final bool required;

  @override
  String toString() => '${level.label}: $label';
}

/// The ordered plan for assembling one profile.
final class ProfileSearchPlan {
  /// Creates a plan.
  const ProfileSearchPlan({
    required this.profileName,
    required this.locations,
    this.projectRoot,
  });

  /// The profile being resolved.
  final String profileName;

  /// The locations, lowest priority first — the order a merge consumes them in.
  final List<ConfigLocation> locations;

  /// The directory whose `alterione.yaml` was found, or null when there is no project level.
  final Uri? projectRoot;

  /// The locations that have a file to read, in priority order.
  Iterable<ConfigLocation> get readable =>
      locations.where((location) => location.path != null);

  /// The highest-priority location for [profileName], which is what `--profile` reports.
  ConfigLocation? get primary => readable.isEmpty ? null : readable.last;

  @override
  String toString() =>
      'ProfileSearchPlan($profileName, ${locations.length} levels, '
      'project: ${projectRoot?.path ?? 'none'})';
}

/// The declared product manifest's file name.
///
/// A constant rather than a string at each use, because §4's precedence rule is stated in terms
/// of *this file name* and a typo in one of the three places that mention it would be a
/// precedence level that silently never applies.
///
/// **The value is the product spelling and the identifier is not.** ADR-0016 puts
/// `alterione.yaml` in the release and `alteri_one_*` in the source tree, and the workspace
/// contract test enforces that by scanning source *code* for the product spelling after
/// stripping comments and string literals. A constant called `alterioneManifestFileName` fails
/// that gate for the same reason a package name would: the value belongs to the release and the
/// name belongs to the source. The string is the product's; this is a library's name for it.
const String productManifestFileName = 'alterione.yaml';

/// The project-level manifest's file name — the same file, as §4 describes it.
const String projectManifestFileName = productManifestFileName;

/// The `profile` block inside a manifest.
const String manifestProfileKey = 'profile';

/// The shape a profile name must have to be usable as a path segment.
///
/// Deliberately the same grammar `config-schema.md` §2 states for `name:`, written out rather
/// than shared, and [profileSearchPlan] says why: this is a precondition for building a path and
/// the schema's rule is a property of a document, and the two answer to different callers.
final _profileNameSegment = RegExp(r'^[a-z][a-z0-9_]*$');

/// Builds the plan for [profileName].
///
/// [projectRoot] is the directory the run started in, or null when there is no project — a
/// library embedder, a test with a temporary root, `doctor` run outside a project. The walk
/// goes up from it looking for [projectManifestFileName] and stops at the first one, which is
/// what §4's "nearest ancestor" means.
///
/// Returns a plan rather than throwing when a directory cannot be inspected: a permission error
/// while walking up is not a reason to refuse a profile that the user level alone can supply,
/// and the plan it returns simply has no project location.
Future<ProfileSearchPlan> profileSearchPlan({
  required Paths paths,
  required String profileName,
  Uri? projectRoot,
  bool walkToRoot = true,
}) async {
  // **A profile name is a path segment, and this is the first place that is true of it.** It
  // becomes `<home>/config/profiles/<name>.yaml` here and `state/<profile>/` in
  // `observability.md` §2, and the schema's `^[a-z][a-z0-9_]*$` is enforced on the *document's*
  // `name:` — not on the name a caller passes to `--profile`, which never reaches the schema at
  // all. So `alterione doctor --profile ../../etc` would otherwise build a path outside the
  // install root and the plan would name it as though it belonged there. A rejected
  // [ArgumentError] is the right answer rather than a silently sanitised name: a user who typed
  // that wants to be told, and a plan that quietly used a different name is a plan nobody can
  // match against the file they meant.
  //
  // The grammar is written out here rather than imported from `validator.dart` because this is a
  // *path-safety* precondition and not a schema rule. A locator that depended on the validator's
  // pattern would be depending on a question the validator was never asked.
  if (!_profileNameSegment.hasMatch(profileName)) {
    throw ArgumentError.value(
      profileName,
      'profileName',
      'is not a single path segment. A profile name becomes a directory name under '
          '${_profileNameSegment.pattern}',
    );
  }

  final locations = <ConfigLocation>[
    ConfigLocation(
      level: ConfigLevel.builtIn,
      kind: ConfigDocumentKind.builtin,
      label: 'built-in defaults',
    ),
  ];

  final userPath = _beneath(paths.profiles, '$profileName.yaml');
  locations.add(
    ConfigLocation(
      level: ConfigLevel.user,
      kind: ConfigDocumentKind.profileFile,
      label: userPath.path,
      path: userPath,
      required: true,
    ),
  );

  final project = await _nearestProjectRoot(
    paths,
    projectRoot,
    walkToRoot: walkToRoot,
  );
  if (project != null) {
    final manifest = _beneath(project, projectManifestFileName);
    locations.add(
      ConfigLocation(
        level: ConfigLevel.project,
        kind: ConfigDocumentKind.manifestProfileBlock,
        label: manifest.path,
        path: manifest,
        subPath: manifestProfileKey,
      ),
    );
  }

  locations.add(
    ConfigLocation(
      level: ConfigLevel.cli,
      kind: ConfigDocumentKind.cliOverride,
      label: 'command-line flags',
    ),
  );

  return ProfileSearchPlan(
    profileName: profileName,
    locations: List<ConfigLocation>.unmodifiable(locations),
    projectRoot: project,
  );
}

/// [directory] with [segment] appended, as a path segment and not as a URI reference.
///
/// **`Uri.resolve` is the wrong call here and the failure is silent.** It follows RFC 3986 and
/// treats the base's last segment as a *file to be replaced*, so
/// `Uri.file('/srv/install/config/profiles').resolve('companion.yaml')` is
/// `/srv/install/config/companion.yaml` — one directory too high, outside `profiles/`, returned
/// by a method whose entire job is to name a file inside it. `paths.dart` documents this trap on
/// [Paths.resolve] and ships [resolveBeneath] for the related one; a locator that resolved with
/// `Uri.resolve` would produce a plan that names a path the product does not read, and the
/// symptom is a profile that is mysteriously "not found" in a directory that plainly contains
/// it.
///
/// [replace] with an explicit path is the operation that was wanted. It also cannot be
/// short-circuited by a segment that looks absolute, which is the second half of the same trap.
Uri _beneath(Uri directory, String segment) {
  final base = directory.path.endsWith('/')
      ? directory.path
      : '${directory.path}/';
  return directory.replace(path: '$base$segment');
}

/// The nearest ancestor of [start] holding a manifest, or null.
///
/// Walks up to the filesystem root and gives up quietly: the answer this needs is "is there a
/// project here", and a directory that cannot be listed or a manifest that cannot be stat'd is
/// not evidence either way. A refusal would make a `doctor` run inside a locked-down directory
/// fail for a reason that has nothing to do with configuration.
///
/// [walkToRoot] exists for the tests, and it is a parameter rather than a shortened path list
/// because "the nearest ancestor" is a rule with one implementation; a test that called the real
/// thing would depend on where the repository happens to live.
Future<Uri?> _nearestProjectRoot(
  Paths paths,
  Uri? start, {
  required bool walkToRoot,
}) async {
  if (start == null) return null;
  var directory = start;
  while (true) {
    // `_beneath`, not `directory.resolve(...)`: see the note there. The wrong one looks for the
    // manifest one directory *above* where it is, so `exists` answered for a path the product
    // does not use and every directory appeared to be a project root.
    if (await paths.exists(_beneath(directory, projectManifestFileName))) {
      return directory;
    }
    if (!walkToRoot) return null;
    final parent = _parentOf(directory);
    if (parent == null) return null;
    directory = parent;
  }
}

/// The parent of a `file:` [Uri], or null when it is the root.
///
/// Written here rather than reaching for `Uri.replace` or `path` arithmetic, because both of
/// those have a documented surprise: `Uri.file('/a/b/').parent` is `/a/`, which is a *directory*
/// and not a path, and joining onto it with `resolve` then gives `/a/project` — one level too
/// high. The walk above is only correct if the parent is the directory above, and this is the one
/// place that has to be sure.
Uri? _parentOf(Uri directory) {
  final segments = directory.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  segments.removeLast();
  final path = segments.isEmpty ? '/' : '/${segments.join('/')}';
  final candidate = Uri(scheme: directory.scheme, path: path);
  if (candidate == directory) return null;
  return candidate;
}
