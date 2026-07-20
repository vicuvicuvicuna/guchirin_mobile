import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Owns the app's single encrypted local database (chat sessions/messages).
///
/// Backed by SQLCipher via sqflite_sqlcipher (drop-in for sqflite, adds a
/// `password:` to openDatabase). The passphrase is a random 256-bit key
/// generated once and stored in flutter_secure_storage (Android Keystore-
/// backed EncryptedSharedPreferences), not a human-remembered secret — this
/// protects the data at rest (e.g. a rooted device or an extracted device
/// backup), not against someone who has the unlocked app open.
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  static const _dbFileName = 'guchirin.db';
  static const _passphraseKey = 'db_passphrase_v1';
  static const _secureStorage = FlutterSecureStorage();

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final passphrase = await _getOrCreatePassphrase();
    final path = p.join(await getDatabasesPath(), _dbFileName);
    return openDatabase(
      path,
      password: passphrase,
      version: 2,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at TEXT NOT NULL,
            summary TEXT NOT NULL DEFAULT '',
            summarized_through INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
          )
        ''');
        await db.execute('CREATE INDEX idx_messages_session_id ON messages(session_id)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Rolling context-compaction summary (see SessionRepository/LlmService.summarize):
          // `summary` holds the folded-down recap of older turns, and
          // `summarized_through` is how many of the session's messages (in
          // created_at order) are already covered by it.
          await db.execute("ALTER TABLE sessions ADD COLUMN summary TEXT NOT NULL DEFAULT ''");
          await db.execute(
            'ALTER TABLE sessions ADD COLUMN summarized_through INTEGER NOT NULL DEFAULT 0',
          );
        }
      },
    );
  }

  Future<String> _getOrCreatePassphrase() async {
    final existing = await _secureStorage.read(key: _passphraseKey);
    if (existing != null) return existing;

    final random = Random.secure();
    final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
    final passphrase = base64Url.encode(keyBytes);
    await _secureStorage.write(key: _passphraseKey, value: passphrase);
    return passphrase;
  }
}
