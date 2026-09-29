// Documentation integrity for the AlteriOne specification.
//
//   dart run tool/docs/check_doc_links.dart             relative links and anchors resolve
//   dart run tool/docs/check_doc_links.dart --orphans   every markdown file is reachable
//
// Exit code 0 on success, 1 on any finding.
//
// Two properties are deliberate.
//
// No third-party dependencies. This runs in CI before any package in the workspace is
// published or resolved, and a documentation gate that needs a resolver to start is a
// documentation gate that silently stops running one day. Hand-rolled argument parsing
// and the standard library only.
//
// Anchor slugs follow GitHub's algorithm: lowercase, drop punctuation other than
// hyphens, collapse whitespace to hyphens. Headings containing punctuation therefore
// generate ambiguous slugs, which is why none of them carry a number whose slug is
// linked from another file.

import 'dart:io';

/// A link that does not resolve, with the location that points at it.
typedef Finding = ({String where, String target, String problem});

const _skipDirectories = {'.git', '.dart_tool', 'build'};
const _externalPrefixes = ['http://', 'https://', 'mailto:'];

final _linkPattern = RegExp(r'\[[^\]]*\]\(([^)]+)\)');
final _headingPattern = RegExp(r'^(#{1,6})\s+(.*?)\s*$');
final _fencePattern = RegExp(r'^\s*(```|~~~)');
final _slugRemovals = RegExp(r'[^\w\s-]');

/// Sets [exitCode] rather than returning it.
///
/// Neither `dart run file.dart` nor `dart file.dart` propagates the value an `int main`
/// returns — both exit 0. A documentation gate that prints its findings and then reports
/// success is worse than no gate, because it is trusted, so the exit code is set through
/// the one mechanism the VM honours.
void main(List<String> arguments) {
  final options = _Options.parse(arguments);

  if (options.help || options.unknown != null) {
    if (options.unknown != null) {
      stderr.writeln('check_doc_links: ${options.unknown}');
      stderr.writeln(_usage);
      exitCode = 1;
      return;
    }
    stdout.writeln(_usage);
    return;
  }

  // Normalised once, so every path this tool builds is comparable with every path it
  // derives from a link. `Directory('.').absolute.path` keeps its `.` segment, and a
  // single un-collapsed root silently turns every file into an orphan.
  final root = _normalise(Directory(options.root).absolute.path);
  final files = _findMarkdown(root);

  if (files.isEmpty) {
    stderr.writeln('no markdown files found');
    exitCode = 1;
    return;
  }

  final anchors = <String, Set<String>>{
    for (final file in files) file: _anchorsOf(file),
  };

  final findings = <Finding>[
    ..._checkLinks(root, files, anchors),
    if (options.orphans) ..._checkOrphans(root, files),
  ];

  if (findings.isNotEmpty) {
    final label = options.orphans ? 'documentation' : 'link';
    stderr.writeln('${findings.length} $label finding(s):');
    for (final finding in findings) {
      final tail = finding.target.isEmpty
          ? '[${finding.problem}]'
          : '${finding.target}  [${finding.problem}]';
      stderr.writeln('  ${finding.where}  $tail');
    }
    exitCode = 1;
    return;
  }

  final mode = options.orphans ? 'links and reachability' : 'links and anchors';
  stdout.writeln('OK: $mode verified across ${files.length} markdown files');
}

const _usage =
    'usage: dart run tool/docs/check_doc_links.dart [--orphans] [--root <dir>]';

final class _Options {
  const _Options({
    required this.root,
    required this.orphans,
    required this.help,
    required this.unknown,
  });

  factory _Options.parse(List<String> arguments) {
    var root = '.';
    var orphans = false;
    String? unknown;

    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      switch (argument) {
        case '--orphans':
          orphans = true;
        case '--root':
          if (i + 1 >= arguments.length) {
            unknown = '--root needs a directory';
            break;
          }
          root = arguments[++i];
        case '-h' || '--help':
          return _Options(
            root: root,
            orphans: orphans,
            help: true,
            unknown: null,
          );
        default:
          unknown = 'unknown argument "$argument"';
      }
      if (unknown != null) break;
    }

    return _Options(
      root: root,
      orphans: orphans,
      help: false,
      unknown: unknown,
    );
  }

  final String root;
  final bool orphans;
  final bool help;
  final String? unknown;
}

List<String> _findMarkdown(String root) {
  final found = <String>[];
  final queue = <String>[root];

  while (queue.isNotEmpty) {
    final directory = Directory(queue.removeLast());
    if (!directory.existsSync()) continue;

    final entries = directory.listSync(followLinks: false);
    for (final entry in entries) {
      final name = entry.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (entry is Directory) {
        if (!_skipDirectories.contains(name)) queue.add(entry.path);
      } else if (name.endsWith('.md')) {
        found.add(entry.path);
      }
    }
  }

  found.sort();
  return found;
}

/// Drops fenced code blocks, where `#` is a comment or a shell prompt, not a heading.
List<String> _stripCode(List<String> lines) {
  final out = <String>[];
  var inFence = false;

  for (final line in lines) {
    if (_fencePattern.hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (!inFence) out.add(line);
  }
  return out;
}

String _slugify(String text) {
  return text
      .replaceAll('`', '')
      .replaceAllMapped(_linkPattern, _linkText)
      .toLowerCase()
      .replaceAll(_slugRemovals, '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '-');
}

/// `[text](target)` contributes `text` to a heading's slug, not its target.
String _linkText(Match match) {
  final whole = match.group(0)!;
  final open = whole.indexOf(']');
  return open <= 1 ? '' : whole.substring(1, open);
}

Set<String> _anchorsOf(String path) {
  final anchors = <String>{};
  final lines = File(path).readAsLinesSync();

  for (final line in _stripCode(lines)) {
    final match = _headingPattern.firstMatch(line);
    if (match != null) anchors.add(_slugify(match.group(2)!));
  }
  return anchors;
}

List<Finding> _checkLinks(
  String root,
  List<String> files,
  Map<String, Set<String>> anchors,
) {
  final findings = <Finding>[];

  for (final path in files) {
    final lines = File(path).readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_fencePattern.hasMatch(line)) continue;
      final where = '${_relative(root, path)}:${i + 1}';

      for (final match in _linkPattern.allMatches(line)) {
        final target = match.group(1)!;
        if (_isExternal(target)) continue;

        final separator = target.indexOf('#');
        final targetPath = separator == -1
            ? target
            : target.substring(0, separator);
        final fragment = separator == -1 ? '' : target.substring(separator + 1);

        final resolved = targetPath.isEmpty
            ? path
            : _normalise(_join(_dirname(path), targetPath));

        if (!File(resolved).existsSync() && !Directory(resolved).existsSync()) {
          findings.add((where: where, target: target, problem: 'missing file'));
        } else if (fragment.isNotEmpty && resolved.endsWith('.md')) {
          final known = anchors[resolved];
          if (known != null && !known.contains(fragment.toLowerCase())) {
            findings.add((
              where: where,
              target: target,
              problem: 'missing anchor',
            ));
          }
        }
      }
    }
  }
  return findings;
}

/// Every markdown file must be reachable by following links from an entry point.
///
/// Reachability is transitive: docs/decisions/0015-*.md is linked from
/// docs/decisions/README.md, which is itself linked from docs/README.md. Checking only
/// direct links would report every such file as an orphan.
List<Finding> _checkOrphans(String root, List<String> files) {
  final entries = [
    _join(root, 'docs/README.md'),
    _join(root, 'README.md'),
  ].where((path) => File(path).existsSync()).toList();

  if (entries.isEmpty) {
    return [
      (
        where: 'no entry point found',
        target: '',
        problem: 'cannot compute reachability',
      ),
    ];
  }

  final known = files.toSet();
  final seen = <String>{};
  final queue = [...entries];

  while (queue.isNotEmpty) {
    final path = queue.removeLast();
    if (!seen.add(path)) continue;
    if (!known.contains(path)) continue;

    final base = _dirname(path);
    for (final line in _stripCode(File(path).readAsLinesSync())) {
      for (final match in _linkPattern.allMatches(line)) {
        final target = match.group(1)!.split('#').first;
        if (target.isEmpty) continue;
        if (_isExternal(target)) continue;
        final resolved = _normalise(_join(base, target));
        if (known.contains(resolved) && !seen.contains(resolved)) {
          queue.add(resolved);
        }
      }
    }
  }

  final orphans = files.where((file) => !seen.contains(file)).toList()..sort();
  return [
    for (final file in orphans)
      (
        where: _relative(root, file),
        target: '',
        problem: 'unreachable from any entry point',
      ),
  ];
}

String _dirname(String path) {
  final normalised = _normalise(path);
  final index = normalised.lastIndexOf(Platform.pathSeparator);
  return index <= 0 ? '.' : normalised.substring(0, index);
}

String _join(String base, String relative) =>
    relative.startsWith('/') || _isAbsolute(relative)
    ? relative
    : '$base${Platform.pathSeparator}$relative';

bool _isExternal(String target) => _externalPrefixes.any(target.startsWith);

bool _isAbsolute(String path) =>
    Platform.isWindows && RegExp(r'^[A-Za-z]:').hasMatch(path);
String _normalise(String path) {
  final separator = Platform.pathSeparator;
  final slashed = path.replaceAll('/', separator);
  final absolute = slashed.startsWith(separator);
  final parts = slashed
      .split(separator)
      .where((part) => part.isNotEmpty && part != '.')
      .toList();

  final out = <String>[];
  for (final part in parts) {
    if (part == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!absolute) {
        out.add('..');
      }
      continue;
    }
    out.add(part);
  }

  final joined = out.join(separator);
  if (absolute) return '$separator$joined';
  return joined.isEmpty ? '.' : joined;
}

String _relative(String root, String path) {
  final normalisedRoot = _normalise(root);
  final prefix = normalisedRoot.endsWith(Platform.pathSeparator)
      ? normalisedRoot
      : '$normalisedRoot${Platform.pathSeparator}';
  final normalisedPath = _normalise(path);
  return normalisedPath.startsWith(prefix)
      ? normalisedPath.substring(prefix.length)
      : normalisedPath;
}
