// Copyright 2026 The AlteriOne Authors.
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:hive_ce/hive_ce.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hive_durability_');
    // API: Hive.init(path) sets the home directory for boxes.
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('Box survives close/reopen with flush', () async {
    // API: Hive.openBox(name) opens (or creates) a Box on disk.
    final box = await Hive.openBox<dynamic>('box1');
    await box.put('k', 'value-1');
    // API: Box.flush() persists pending writes to disk.
    await box.flush();
    // API: Box.close() closes the box (and underlying file handle).
    await box.close();

    // Reopen in a fresh Hive instance context (same path).
    Hive.init(tempDir.path);
    final reopened = await Hive.openBox<dynamic>('box1');
    // API: Box.get(key) reads a value.
    expect(reopened.get('k'), equals('value-1'));
    await reopened.close();
  });

  test('LazyBox survives close/reopen with flush', () async {
    // API: Hive.openLazyBox(name) opens (or creates) a LazyBox on disk.
    final lazy = await Hive.openLazyBox<dynamic>('lazy1');
    await lazy.put('k', 42);
    // API: LazyBox.flush() persists pending writes to disk.
    await lazy.flush();
    // API: LazyBox.close() closes the lazy box.
    await lazy.close();

    Hive.init(tempDir.path);
    final reopened = await Hive.openLazyBox<dynamic>('lazy1');
    // API: LazyBox.get(key) reads a value (async).
    expect(await reopened.get('k'), equals(42));
    await reopened.close();
  });
}
