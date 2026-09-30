/// Where the product reads and writes, as one derived root.
///
/// [architecture/install-and-update.md] §2 fixes the shape of the install root and
/// [architecture/workspace-layout.md] §4 fixes how configuration is layered inside it. Both are
/// normative and both mention `ALTERIONE_HOME`, so the one thing every consumer needs first is the
/// root itself; everything else here is that root plus a fixed relative path, which is what makes
/// the whole layout checkable by a test rather than by reading a tree diagram.
///
/// ## Why a port and not a set of constants
///
/// [architecture/overview.md] §4 makes `apps/cli` the composition root, and this is one of the
/// reasons: which directories exist is a *deployment* decision, and the deployment root differs
/// between a source checkout, a test, the `developer` profile and an installed release. A constant
/// like `~/.alterione` in product code is correct only in the last of those four. Injecting the
/// root is what lets task `0.21`'s offline harness and task `1.1`'s storage tests run against a
/// temporary directory without any of them knowing the layout.
///
/// ## The two layout documents do not agree, and this port follows one
///
/// This is stated rather than smoothed over, because the alternative is a port that quietly picks
/// a layout and a documentation gate that passes on both readings.
///
/// - [architecture/install-and-update.md] §2, titled *The install root*, groups user state:
///   `config/` holds `profiles/`, `policies.d/` and `config.yaml`, with `state/` and `logs/` as
///   its siblings.
/// - [architecture/workspace-layout.md] §4 shows the same tree with `profiles/`, `policies.d/`,
///   `injections/`, `tools/`, `plugins/`, `config.yaml` and `state/` **all at the top level**.
///
/// The two are not reconcilable by reading. This port follows install-and-update.md §2, because
/// that section is the one that defines an install root as a thing rather than illustrating which
/// files participate in configuration precedence, and because a nested `config/` is what lets the
/// install root keep a stable set of *release* files at the top — `alterione.aot`, `manifest.json`,
/// `bin/` — that an updater rewrites atomically without walking past user state. The divergence
/// is tracked as a work item rather than resolved here: deciding it changes where a user's memory
/// lives, and that is not this port's decision to make quietly. [TODO.md] carries it.
///
/// ## `Uri`, not `String`
///
/// Every path here is a [Uri] with no scheme and no authority. Three reasons, each one a bug it
/// prevents: a Windows path contains a drive letter that is not a Uri path segment, so
/// `Uri.parse('C:\\Users\\me')` does not do what it looks like it does and the value has to be
/// built rather than parsed; [Uri.resolve] gives correct relative joining on every platform
/// without a `Platform.pathSeparator` branch in product code; and a `Uri` cannot be
/// `~/`-prefixed by accident, which is the single most common way a path escapes the root the user
/// configured.
///
/// The paths are **not** resolved to absolute, canonical form here. Symlinks and `..` are the
/// host's business, and a port that resolved them would be doing the containment check that task
/// `0.24`'s `x-path-root` rule and `doctor`'s validation belong to.
///
/// ## What this port does not decide
///
/// It does not create anything. [ensure] is here because a directory has to exist before it can be
/// opened, and the port that opens it should not have to know that it might not. It is not a
/// general filesystem: reading, writing and deleting a *tool's* payload is `tools/fs`, a Tool noun,
/// not a platform port, and the difference is authority — [paths.dart] is reachable from the
/// composition root and `fs.*` is reachable only through policy.
///
/// [architecture/install-and-update.md]: ../../../../docs/architecture/install-and-update.md
/// [architecture/workspace-layout.md]: ../../../../docs/architecture/workspace-layout.md
/// [architecture/overview.md]: ../../../../docs/architecture/overview.md
/// [TODO.md]: ../../../../TODO.md
library;

/// The layout of one AlteriOne install root, as absolute [Uri]s.
///
/// Every member is derived from [home], so there is exactly one value a caller has to be able to
/// change and no member can disagree with another about where the install root is.
abstract interface class Paths {
  /// The install root: `$ALTERIONE_HOME`, or `~/.alterione`.
  ///
  /// Never `~`, and never a relative path. A launcher that resolves its own directory
  /// ([architecture/install-and-update.md] §2.1) and a core that resolved `.` would disagree about
  /// where memory lives the moment the CLI was started from anywhere but the install root — which
  /// is every invocation.
  ///
  /// A `file:` [Uri] on this platform — built with [Uri.file] — so that a Windows drive letter
  /// survives the round trip. It is *not* a `Uri.parse` of a path string: `Uri.parse(r'C:\Users')`
  /// yields a relative URI with an opaque path, which is the failure this shape exists to prevent.
  Uri get home;

  /// `<home>/config` — user configuration: profiles, policies and `config.yaml`.
  Uri get config;

  /// `<home>/config/profiles` — one YAML file per profile.
  Uri get profiles;

  /// `<home>/config/policies.d` — one policy file per concern.
  ///
  /// The trailing `d` is from `policy.d`, not a typo, and it is part of the name in every document
  /// that mentions it. A port that normalised it would write policy files where the launcher and
  /// `doctor` do not look for them.
  Uri get policies;

  /// `<home>/state` — runtime state: locks, indexes and transcripts.
  ///
  /// Deliberately **not** under [config]. State is written constantly and by concurrent
  /// processes, configuration is written by hand; an updater that swaps [config] wholesale must not
  /// take the lock files and the transcript store with it.
  Uri get state;

  /// `<home>/logs` — diagnostics.
  Uri get logs;

  /// `<home>/injections` — installed Tier 0 skill-pack data and Tier 2 injection executables.
  Uri get injections;

  /// `<home>/tools` — installed Tier 2 tool executables and Tier 0 data.
  Uri get tools;

  /// `<home>/plugins` — installed Tier 2 plugin executables.
  Uri get plugins;

  /// `<home>/bin` — the pinned AOT runtime.
  Uri get bin;

  /// `<home>/apps` — the deployed subprojects, mirroring the repository's `apps/`.
  Uri get apps;

  /// [relative] resolved against [home].
  ///
  /// The escape hatch for a path the layout does not name — a profile's own state directory under
  /// `state/<profile>/`, a Tier 2 tool's working directory.
  ///
  /// **Throws [ArgumentError] for anything that is not relative to [home].** A leading `/`, a
  /// `file:` scheme, or a Windows drive letter. Not a normalisation: [Uri.resolve]'s own rule is
  /// that an absolute reference on the right *replaces* the base, so `resolve('/etc/passwd')` on a
  /// `file:` base returns `file:///etc/passwd` — a real path, silently, from a method whose name
  /// says it joins onto the root. A caller that was handed a root cannot be handed a path
  /// somewhere else by passing one, and the one way to be handed one is the way that looks
  /// harmless.
  ///
  /// `..` is **not** rejected here, because `state/<profile>/../other` is a legitimate way to
  /// write a sibling and [within] is the check that answers the question. This method's contract is
  /// about the *anchor*, not about the result.
  ///
  /// Implemented with [resolveBeneath], which is where the validation lives. It is a member and not
  /// only a function for the same reason every port member is: the browser surface has to **refuse**
  /// it rather than return a plausible path, and an implementation that inherited the logic from the
  /// interface would return a `file:` URI on a platform with no filesystem at all.
  Uri resolve(String relative);

  /// Whether [candidate] is [home] or lies beneath it.
  ///
  /// Lexical and therefore **not** a security boundary: `..` is compared as its own segment and a
  /// symlink inside the root is still followed. It answers the question the layout actually needs
  /// answered — "did this path come from this root", for a path this port composed — and the
  /// authoritative containment check is task `0.24`'s `x-path-root` rule with a resolved real path.
  /// A port that claimed otherwise would be a security claim with a `..` in it.
  ///
  /// Implemented with [isBeneath], for the reason [resolve] states.
  bool within(Uri candidate);

  /// Creates [directory] and every missing parent, and reports whether it had to.
  ///
  /// `false` when it already existed, which is the normal case on a second run, or when [create] is
  /// `false` — reading the layout must not leave a directory behind on a machine where the product
  /// has never run.
  ///
  /// Creating is idempotent and never throws for an existing directory. That is the whole method:
  /// the lock file, the transcript store and the log directory all need a root that exists before
  /// they can be opened, and each of those is a caller that would otherwise repeat
  /// "create if missing" three times with three different ideas about permissions.
  Future<bool> ensure(Uri directory, {bool create = true});

  /// Creates [directory] and every missing parent.
  ///
  /// Separate from [ensure] because [ensure] asks whether it had to and this one does not, and a
  /// caller that wants only the side effect should not pay for the question.
  Future<void> createDirectory(Uri directory);

  /// Whether [path] exists as a directory.
  Future<bool> exists(Uri path);
}

/// [relative] joined onto [home], refusing anything that is not relative to it.
///
/// The shared implementation of [Paths.resolve], and a public function rather than an inherited
/// interface method for the reason [Paths.resolve] states: it is logic every implementation wants
/// and the browser surface must refuse it rather than inherit it. A test fake calls this rather
/// than re-deriving the validation, which is what makes "fake injection" a one-liner per member
/// instead of a copy of the rule that has to be kept in step.
///
/// Throws [ArgumentError] for an empty [relative], a leading `/` or `\`, or anything with a URI
/// scheme. Not for `..`: [Paths.resolve] rejects the *anchor* escaping, and [isBeneath] is what
/// answers whether a resolved path is still inside the root.
Uri resolveBeneath(Uri home, String relative) {
  if (relative.isEmpty) {
    throw ArgumentError.value(
      relative,
      'relative',
      'is empty. Resolve the install root itself with `home` rather than with `resolve("")`, '
          'which would make the root and one of its children two spellings of one path',
    );
  }
  if (relative.startsWith('/') ||
      relative.startsWith(r'\') ||
      hasUriScheme(relative)) {
    throw ArgumentError.value(
      relative,
      'relative',
      'is not relative to the install root. `Uri.resolve` treats an absolute reference on the '
          'right as replacing the base, so this would return a path somewhere else entirely '
          'while appearing to join onto the root',
    );
  }
  // **Appended, not `Uri.resolve`d.** The trap, and it is the reason this is a function rather than
  // a one-liner: `Uri.resolve` follows RFC 3986 and treats the base's last segment as a *file* to be
  // replaced, so `Uri.file('/srv/install').resolve('config')` is `/srv/config` — outside the install
  // root, from a method whose whole purpose is to produce a path inside it. The caller had no way to
  // see that, because the returned path looks exactly like a joined one.
  final base = home.path.endsWith('/') ? home.path : '${home.path}/';
  return home.replace(path: '$base$relative');
}

/// Whether [candidate] is [home] itself or lies strictly beneath it.
///
/// Segment-wise over the paths as written. `..` needs no special handling because a [Uri] **cannot
/// carry one**: the unnamed constructor, [Uri.parse] and [Uri.file] all resolve `..` before the value
/// exists, so `Uri(scheme: 'file', path: '/a/b/../c').path` is already `/a/c`. An earlier version of
/// this function rejected a `..` segment and the check was unreachable from every constructor there
/// is — a guard against nothing, which is worse than no guard because it reads as protection.
///
/// What that leaves is a *lexical* check, and the limitation is a symlink: `<root>/link -> /etc` is
/// beneath the root by every segment and resolves outside it. So this answers "did this path come
/// from this root, for a path this port composed", and the authoritative containment check is task
/// `0.24`'s `x-path-root` rule against a **real** path. A port that claimed otherwise would be a
/// security claim with a symlink in it.
///
/// A scheme or authority mismatch answers `false` rather than throwing: a `file:` URI and a `https:`
/// URI are not two paths to compare, and a caller passing one has made a mistake this function can
/// describe but cannot fix.
bool isBeneath(Uri home, Uri candidate) =>
    candidate == home || _strictlyBeneath(home, candidate);

/// Whether [relative] starts with something that parses as a URI scheme.
///
/// `Uri.parse` accepts `c:something` as a scheme, so a bare Windows drive letter would otherwise
/// pass as a relative segment and be joined onto the root as `…/.alterione/C:/Windows`. Checking
/// it here is what keeps [resolveBeneath]'s promise on a platform where that is a real path.
bool hasUriScheme(String relative) {
  final colon = relative.indexOf(':');
  if (colon < 1) return false;
  final first = relative.codeUnitAt(0);
  if (!((first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A))) {
    return false;
  }
  for (var index = 1; index < colon; index++) {
    final unit = relative.codeUnitAt(index);
    final isLetter =
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
    final isDigit = unit >= 0x30 && unit <= 0x39;
    if (!isLetter && !isDigit && unit != 0x2B && unit != 0x2D && unit != 0x2E) {
      return false;
    }
  }
  return true;
}

/// Whether [candidate] is strictly beneath [root].
bool _strictlyBeneath(Uri root, Uri candidate) {
  if (root.scheme != candidate.scheme) return false;
  if (root.authority.isNotEmpty && root.authority != candidate.authority) {
    return false;
  }
  final rootSegments = root.pathSegments.where((s) => s.isNotEmpty).toList();
  final candidateSegments = candidate.pathSegments.where((s) => s.isNotEmpty);
  if (candidateSegments.length <= rootSegments.length) return false;
  for (var index = 0; index < rootSegments.length; index++) {
    if (candidateSegments.elementAt(index) != rootSegments[index]) return false;
  }
  // Every segment of [candidate] below [root] matched, and a `Uri` carries no `..` — see [isBeneath].
  return true;
}
