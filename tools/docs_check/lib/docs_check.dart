// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;

/// Verifies that documentation links resolve, that forbidden terms from
/// `docs/spec/forbidden-glossary.md` are absent, and that `AGENTS.md` and
/// `CLAUDE.md` exist in the required directories.
class DocsChecker {
  /// Returns a list of violation descriptions. Empty when all rules hold.
  List<String> check(Directory root) {
    final rootPath = p.normalize(root.path);
    final violations = <String>[];

    // 1. Required AGENTS.md and CLAUDE.md in root and group directories.
    const requiredDirs = <String>[
      '',
      'packages',
      'providers',
      'extensions',
      'runtime',
      'runtime/core',
      'clients',
      'e2e',
      'tools',
    ];
    for (final relDir in requiredDirs) {
      final dir = Directory(
        relDir.isEmpty ? rootPath : p.join(rootPath, relDir),
      );
      for (final name in const ['AGENTS.md', 'CLAUDE.md']) {
        final file = File(p.join(dir.path, name));
        if (!file.existsSync()) {
          final rel = relDir.isEmpty ? name : '$relDir/$name';
          violations.add('missing required file: $rel');
        }
      }
    }

    // 2. Broken inline links in Markdown files.
    final mdFiles = <File>[];
    _collectFiles(root, mdFiles, (f) => f.path.toLowerCase().endsWith('.md'));
    for (final md in mdFiles) {
      final rel = p
          .relative(md.path, from: rootPath)
          .split(p.separator)
          .join('/');
      String content;
      try {
        content = md.readAsStringSync();
      } catch (_) {
        continue;
      }
      final dir = md.parent;
      for (final match in RegExp(
        r'\[([^\]]*)\]\(([^)]*)\)',
      ).allMatches(content)) {
        final target = match.group(2)!;
        final trimmed = target.trim();
        if (trimmed.isEmpty) continue;
        final lower = trimmed.toLowerCase();
        if (lower.startsWith('http://') ||
            lower.startsWith('https://') ||
            lower.startsWith('mailto:')) {
          continue;
        }
        if (trimmed.startsWith('#')) continue;
        final pathPart = trimmed.split('#').first.split('?').first.trim();
        if (pathPart.isEmpty) continue;
        final resolved = p.normalize(p.join(dir.path, pathPart));
        final exists =
            File(resolved).existsSync() || Directory(resolved).existsSync();
        if (!exists) {
          violations.add('broken link in $rel: $target');
        }
      }
    }

    // 3. Forbidden terms from the glossary.
    const glossaryRel = 'docs/spec/forbidden-glossary.md';
    final glossaryFile = File(
      p.join(rootPath, 'docs', 'spec', 'forbidden-glossary.md'),
    );
    final terms = <String>[];
    if (glossaryFile.existsSync()) {
      try {
        terms.addAll(_parseGlossary(glossaryFile));
      } catch (_) {
        // ignore
      }
    }
    if (terms.isNotEmpty) {
      final allFiles = <File>[];
      _collectFiles(root, allFiles, (_) => true);
      for (final file in allFiles) {
        final rel = p
            .relative(file.path, from: rootPath)
            .split(p.separator)
            .join('/');
        if (rel == glossaryRel) continue;
        if (rel.toLowerCase().endsWith('.md')) continue;
        String content;
        try {
          content = file.readAsStringSync();
        } catch (_) {
          continue;
        }
        final lower = content.toLowerCase();
        for (final term in terms) {
          if (term.isEmpty) continue;
          if (lower.contains(term.toLowerCase())) {
            violations.add("forbidden term '$term' in $rel");
          }
        }
      }
    }

    return violations;
  }

  static void _collectFiles(
    Directory dir,
    List<File> out,
    bool Function(File) accept,
  ) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
    } catch (_) {
      return;
    }
    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (name == '.dart_tool' || name == 'build' || name == '.git') {
          continue;
        }
        _collectFiles(entity, out, accept);
      } else if (entity is File && accept(entity)) {
        out.add(entity);
      }
    }
  }

  static List<String> _parseGlossary(File file) {
    final lines = file.readAsLinesSync();
    var start = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains('|')) {
        start = i;
        break;
      }
    }
    if (start < 0) return const [];
    final block = <String>[];
    for (var i = start; i < lines.length; i++) {
      if (!lines[i].contains('|')) break;
      block.add(lines[i]);
    }
    if (block.length < 3) return const [];
    final seen = <String>{};
    final terms = <String>[];
    for (var i = 2; i < block.length; i++) {
      final line = block[i];
      final cells = line.split('|');
      String first;
      if (line.trim().startsWith('|') && cells.length >= 2) {
        first = cells[1];
      } else {
        first = cells.first;
      }
      final term = first.replaceAll('`', '').trim();
      if (term.isEmpty) continue;
      if (seen.add(term.toLowerCase())) {
        terms.add(term);
      }
    }
    return terms;
  }
}
