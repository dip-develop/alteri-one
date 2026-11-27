// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:alteri_one_contracts/alteri_one_contracts.dart';
import 'package:alteri_one_core/alteri_one_core.dart';
import 'package:test/test.dart';

ExtensionManifest _manifest({
  List<String> permissions = const [],
  List<String> observes = const [],
  List<String> skills = const [],
}) => ExtensionManifest(
  id: 'weather',
  version: '1.0.0',
  contract: '2.0.0',
  sdk: '3.14.0',
  target: 'linux-x64',
  provides: ExtensionProvides(
    tools: const ['forecast'],
    triggers: const [],
    channels: const [],
    context: const [],
    memoryBackend: false,
    skills: skills,
  ),
  permissions: permissions,
  observes: observes,
  sha256: 'abc123',
  signature: 'deadbeef',
);

void main() {
  group('ApprovalLoader.load', () {
    final loader = ApprovalLoader(Directory('.'));

    test('grants the intersection of the manifest and the owner file', () {
      final manifest = _manifest(
        permissions: ['net:api.open-meteo.com', 'host.memory.read'],
        observes: ['runs', 'approvals'],
        skills: ['forecast', 'alerts'],
      );
      final approval = loader.load(
        manifest: manifest,
        yamlText: '''
permissions:
  - net:api.open-meteo.com
  - host.fs:/tmp
observes:
  - runs
skills:
  - alerts
''',
      );

      expect(approval.permissions.granted, {'net:api.open-meteo.com'});
      expect(approval.observes, {'runs'});
      expect(approval.skills, {'alerts'});
    });

    test('denies a permission the manifest does not declare', () {
      final manifest = _manifest(permissions: ['host.memory.read']);
      final approval = loader.load(
        manifest: manifest,
        yamlText: 'permissions:\n  - net:evil.example\n',
      );

      expect(approval.permissions.granted, isEmpty);
      expect(approval.permissions.grants('net:evil.example'), isFalse);
    });

    test('an empty file grants nothing (default deny)', () {
      final manifest = _manifest(
        permissions: ['host.memory.read'],
        observes: ['runs'],
        skills: ['forecast'],
      );
      final approval = loader.load(manifest: manifest, yamlText: '{}\n');

      expect(approval.permissions.granted, isEmpty);
      expect(approval.observes, isEmpty);
      expect(approval.skills, isEmpty);
    });

    test('throws a FormatException on a non-mapping document', () {
      final manifest = _manifest();
      expect(
        () => loader.load(manifest: manifest, yamlText: '- a\n- b\n'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ApprovalLoader.read', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('approvals');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('reads extensions/<id>.yaml from the directory', () {
      File('${dir.path}${Platform.pathSeparator}weather.yaml')
          .writeAsStringSync('permissions:\n  - host.memory.read\n');
      final loader = ApprovalLoader(dir);
      final manifest = _manifest(permissions: ['host.memory.read']);

      final effective = loader.read(manifest);

      expect(effective.permissions.granted, {'host.memory.read'});
      expect(effective.permissions.grants('host.memory.read'), isTrue);
    });

    test('a missing file under the directory is a default deny', () {
      final loader = ApprovalLoader(dir);
      final effective = loader.read(
        _manifest(permissions: ['host.memory.read']),
      );

      expect(effective.permissions.granted, isEmpty);
    });
  });
}
