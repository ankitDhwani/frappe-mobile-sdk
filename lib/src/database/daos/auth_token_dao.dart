import 'package:sqflite/sqflite.dart';
import '../../utils/sdk_log.dart';
import '../entities/auth_token_entity.dart';

class AuthTokenDao {
  final Database _database;

  AuthTokenDao(this._database);

  Future<AuthTokenEntity?> getCurrentToken() async {
    final maps = await _database.query(
      'auth_tokens',
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AuthTokenEntity.fromDb(maps.first);
  }

  Future<void> insertToken(AuthTokenEntity token) async {
    await _database.insert(
      'auth_tokens',
      token.toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// [insertToken], then scrubs what the replaced row left on disk:
  /// `secure_delete` zeroes the freed record instead of leaving its bytes in
  /// the page, and a TRUNCATE checkpoint drops the WAL frames that still hold
  /// it. For replacing a row that held a secret. The pragmas are best effort
  /// and never fail the write.
  Future<void> replaceTokenScrubbingOld(AuthTokenEntity token) async {
    Object? previous;
    try {
      final rows = await _database.rawQuery('PRAGMA secure_delete');
      previous = rows.isEmpty ? null : rows.first.values.first;
      await _database.rawQuery('PRAGMA secure_delete = 1');
    } catch (e) {
      sdkLog('AuthTokenDao: secure_delete unavailable — $e');
    }
    try {
      await insertToken(token);
    } finally {
      try {
        if (previous is int) {
          await _database.rawQuery('PRAGMA secure_delete = $previous');
        }
        await _database.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (e) {
        sdkLog('AuthTokenDao: scrub after token replace failed — $e');
      }
    }
  }

  Future<void> updateToken(AuthTokenEntity token) async {
    await _database.update(
      'auth_tokens',
      token.toDb(),
      where: 'id = ?',
      whereArgs: [token.id],
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAll() async {
    await _database.delete('auth_tokens');
  }
}
