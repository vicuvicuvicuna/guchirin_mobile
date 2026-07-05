// On-device verification of the encrypted session DB, independent of
// flutter_gemma (which currently can't install its .litertlm model on the
// x86_64 emulator this was written against). Run with:
//   flutter test integration_test/session_repository_test.dart -d <device>
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart' show getDatabasesPath;

import 'package:guchirin_mobile/models/chat_message_record.dart';
import 'package:guchirin_mobile/services/database_service.dart';
import 'package:guchirin_mobile/services/session_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('session CRUD, auto-title, and cascade delete', (tester) async {
    final repo = SessionRepository(DatabaseService.instance);

    final sessionA = await repo.createSession();
    final sessionB = await repo.createSession();
    expect(sessionA.title, SessionRepository.defaultTitle);

    await repo.maybeAutoTitle(sessionA.id, '今日は仕事でつらいことがあった');
    await repo.addMessage(sessionA.id, isUser: true, content: '今日は仕事でつらいことがあった');
    await repo.addMessage(sessionA.id, isUser: false, content: 'それは大変でしたね');
    await repo.addMessage(sessionB.id, isUser: true, content: '別のセッションのメッセージ');

    final sessions = await repo.listSessions();
    final refreshedA = sessions.firstWhere((s) => s.id == sessionA.id);
    expect(refreshedA.title, '今日は仕事でつらいことがあった');
    expect(sessions.map((s) => s.id), containsAll([sessionA.id, sessionB.id]));

    final messagesA = await repo.listMessages(sessionA.id);
    expect(messagesA.map((m) => m.content).toList(), [
      '今日は仕事でつらいことがあった',
      'それは大変でしたね',
    ]);
    expect(messagesA[0].role, MessageRole.user);
    expect(messagesA[1].role, MessageRole.assistant);

    final messagesB = await repo.listMessages(sessionB.id);
    expect(messagesB.length, 1);

    await repo.renameSession(sessionA.id, 'カスタムタイトル');
    await repo.maybeAutoTitle(sessionA.id, 'この文言はもう反映されないはず');
    final afterRename = await repo.listSessions();
    expect(afterRename.firstWhere((s) => s.id == sessionA.id).title, 'カスタムタイトル');

    await repo.deleteSession(sessionB.id);
    final afterDelete = await repo.listSessions();
    expect(afterDelete.any((s) => s.id == sessionB.id), isFalse);
    expect(await repo.listMessages(sessionB.id), isEmpty);
  });

  testWidgets('database file on disk is not plaintext SQLite (SQLCipher active)', (tester) async {
    // Touch the repository first so the DB is guaranteed to exist/be open.
    await SessionRepository(DatabaseService.instance).createSession();

    final dbPath = p.join(await getDatabasesPath(), 'guchirin.db');
    final bytes = await File(dbPath).readAsBytes();
    final header = bytes.sublist(0, 16);
    const plaintextSqliteHeader = 'SQLite format 3\x00';

    expect(
      utf8.decode(header, allowMalformed: true) == plaintextSqliteHeader,
      isFalse,
      reason:
          'DB file header matches the plaintext SQLite signature — SQLCipher '
          'encryption does not appear to be active.',
    );
  });
}
