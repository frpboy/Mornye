import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_schema.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_process_database.dart';

/// The download engine's native writer shares history.db from another
/// process. When it (or a library merge) holds the write lock past one
/// SQLite busy timeout, the Dart history write used to surface
/// "database is locked" as a failed download. These tests prove the history
/// write paths now retry the lock instead.
void main() {
  sqfliteFfiInit();

  late Directory root;
  late Database app;
  late SqliteProcessDatabase native;

  Map<String, dynamic> historyJson(String id) => DownloadHistoryItem(
    id: id,
    trackName: 'Track $id',
    artistName: 'Artist',
    albumName: 'Album',
    filePath: '${root.path}/$id.flac',
    service: 'test',
    downloadedAt: DateTime.utc(2026, 11, 21),
  ).toJson();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('history-busy-retry-');
    final path = '${root.path}/history.db';
    app = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: HistoryDatabase.schemaVersion,
        onConfigure: (db) async {
          // Mirrors openAppDatabase's production pragmas.
          await db.rawQuery('PRAGMA busy_timeout = 5000');
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, version) async {
          await HistorySchema.create(db, version);
        },
      ),
    );
    native = await SqliteProcessDatabase.open(path: path);
    HistoryDatabase.debugReplaceDatabaseForTest(app);
  });

  tearDown(() async {
    HistoryDatabase.debugReplaceDatabaseForTest(null);
    await native.close();
    await app.close();
    await root.delete(recursive: true);
  });

  test('upsert outlives a native write lock held past one busy timeout', () async {
    // A competing process takes the write lock for longer than the 5s
    // busy_timeout, then releases it, like a native library merge finishing.
    await native.execute('BEGIN IMMEDIATE');
    final release = Future<void>.delayed(
      const Duration(seconds: 6),
      () => native.execute('COMMIT'),
    );

    final watch = Stopwatch()..start();
    await HistoryDatabase.instance.upsert(historyJson('id-1'));
    watch.stop();
    await release;

    expect(
      watch.elapsed,
      greaterThan(const Duration(seconds: 5)),
      reason: 'the write must retry past the first busy timeout, not fail',
    );
    expect(await HistoryDatabase.instance.getById('id-1'), isNotNull);
  });

  test('upsertBatch outlives the same contention', () async {
    await native.execute('BEGIN IMMEDIATE');
    final release = Future<void>.delayed(
      const Duration(seconds: 6),
      () => native.execute('COMMIT'),
    );

    await HistoryDatabase.instance.upsertBatch([
      historyJson('id-2'),
      historyJson('id-3'),
    ]);
    await release;

    expect(await HistoryDatabase.instance.getById('id-2'), isNotNull);
    expect(await HistoryDatabase.instance.getById('id-3'), isNotNull);
  });
}
