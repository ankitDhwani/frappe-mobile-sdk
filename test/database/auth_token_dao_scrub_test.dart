// When a row that held a token is replaced by one without it, the old bytes
// must not survive in the database file or its WAL: a copy of either would
// otherwise still carry the credential.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/database/daos/auth_token_dao.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';

const _secret = 'AT-SECRET-7c1e9f0b2d4a';

void main() {
  late Directory dir;
  late String path;
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auth_token_scrub');
    path = '${dir.path}/app.db';
    db = await databaseFactoryFfi.openDatabase(path);
    await db.rawQuery('PRAGMA journal_mode=WAL');
    // SQLite's default, and what a plain replace leaks under.
    await db.rawQuery('PRAGMA secure_delete = 0');
    await db.execute('''
      CREATE TABLE auth_tokens (
        id INTEGER PRIMARY KEY,
        accessToken TEXT NOT NULL,
        refreshToken TEXT NOT NULL,
        user TEXT NOT NULL,
        fullName TEXT,
        createdAt INTEGER NOT NULL
      )
    ''');
    final dao = AuthTokenDao(db);
    await dao.insertToken(
      AuthTokenEntity(
        accessToken: _secret,
        refreshToken: 'RT-$_secret',
        user: 'field@example.org',
        createdAt: 1,
      ),
    );
    // Put the token into the main file as well as the WAL, as on a device
    // that has run for a while.
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
    await dir.delete(recursive: true);
  });

  Future<bool> secretOnDisk() async {
    for (final name in ['app.db', 'app.db-wal']) {
      final f = File('${dir.path}/$name');
      if (!f.existsSync()) continue;
      final text = latin1.decode(await f.readAsBytes());
      if (text.contains(_secret)) return true;
    }
    return false;
  }

  final blank = AuthTokenEntity(
    accessToken: '',
    refreshToken: '',
    user: 'field@example.org',
    createdAt: 1,
  );

  // The files are read while the database is open, as a copy taken from a
  // running app would be. Closing checkpoints the WAL and hides the leak.
  test('a plain replace leaves the old token on disk (control)', () async {
    await AuthTokenDao(db).insertToken(blank);

    expect(await secretOnDisk(), isTrue);
  });

  test('replaceTokenScrubbingOld leaves no trace of the old token', () async {
    await AuthTokenDao(db).replaceTokenScrubbingOld(blank);

    final row = await AuthTokenDao(db).getCurrentToken();
    expect(row!.accessToken, isEmpty);
    expect(row.user, 'field@example.org');
    expect(await secretOnDisk(), isFalse);
  });

  test('restores the previous secure_delete setting', () async {
    await AuthTokenDao(db).replaceTokenScrubbingOld(blank);

    final rows = await db.rawQuery('PRAGMA secure_delete');
    expect(rows.first.values.first, 0);
  });
}
