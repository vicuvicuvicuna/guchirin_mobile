import 'dart:math';

import '../models/chat_message_record.dart';
import '../models/session.dart';
import 'database_service.dart';

/// CRUD for chat sessions/messages, mirroring guchirin_dev's
/// backend/history.py schema and behavior (default title, placeholder-title
/// detection for auto-titling, explicit cascade delete).
class SessionRepository {
  SessionRepository(this._dbService);

  final DatabaseService _dbService;

  static const defaultTitle = '新しいチャット';

  // Same placeholder set as backend/history.py's maybe_set_title, so a
  // session only gets auto-titled from its first message while it still has
  // one of these default names.
  static const _placeholderTitles = {'新しいチャット', 'New Chat', '새 채팅', '新建聊天'};

  Future<Session> createSession() async {
    final db = await _dbService.database;
    final session = Session(id: _newId(), title: defaultTitle, createdAt: DateTime.now());
    await db.insert('sessions', session.toMap());
    return session;
  }

  Future<List<Session>> listSessions() async {
    final db = await _dbService.database;
    final rows = await db.query('sessions', orderBy: 'created_at DESC');
    return rows.map(Session.fromMap).toList();
  }

  Future<Session?> getSession(String sessionId) async {
    final db = await _dbService.database;
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [sessionId]);
    if (rows.isEmpty) return null;
    return Session.fromMap(rows.first);
  }

  /// Persists the result of a context-compaction pass (see
  /// LlmService.summarize): [summary] replaces the prior recap and
  /// [summarizedThrough] advances to mark those messages as folded in.
  Future<void> updateSummary(
    String sessionId, {
    required String summary,
    required int summarizedThrough,
  }) async {
    final db = await _dbService.database;
    await db.update(
      'sessions',
      {'summary': summary, 'summarized_through': summarizedThrough},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<List<ChatMessageRecord>> listMessages(String sessionId) async {
    final db = await _dbService.database;
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
    return rows.map(ChatMessageRecord.fromMap).toList();
  }

  Future<void> addMessage(String sessionId, {required bool isUser, required String content}) async {
    final db = await _dbService.database;
    final record = ChatMessageRecord(
      id: _newId(),
      sessionId: sessionId,
      role: isUser ? MessageRole.user : MessageRole.assistant,
      content: content,
      createdAt: DateTime.now(),
    );
    await db.insert('messages', record.toMap());
  }

  Future<void> maybeAutoTitle(String sessionId, String firstUserMessage) async {
    final db = await _dbService.database;
    final rows = await db.query(
      'sessions',
      columns: ['title'],
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    if (rows.isEmpty) return;
    final currentTitle = rows.first['title'] as String;
    if (!_placeholderTitles.contains(currentTitle)) return;

    final trimmed = firstUserMessage.trim();
    final newTitle = trimmed.isEmpty
        ? defaultTitle
        : trimmed.substring(0, trimmed.length < 30 ? trimmed.length : 30);
    await db.update('sessions', {'title': newTitle}, where: 'id = ?', whereArgs: [sessionId]);
  }

  Future<void> renameSession(String sessionId, String newTitle) async {
    final db = await _dbService.database;
    await db.update('sessions', {'title': newTitle}, where: 'id = ?', whereArgs: [sessionId]);
  }

  Future<void> deleteSession(String sessionId) async {
    final db = await _dbService.database;
    await db.transaction((txn) async {
      await txn.delete('messages', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
    });
  }

  String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
