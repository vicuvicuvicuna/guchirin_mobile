enum MessageRole { user, assistant }

/// A single persisted chat turn belonging to a [Session].
class ChatMessageRecord {
  const ChatMessageRecord({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String sessionId;
  final MessageRole role;
  final String content;
  final DateTime createdAt;

  factory ChatMessageRecord.fromMap(Map<String, Object?> map) => ChatMessageRecord(
    id: map['id'] as String,
    sessionId: map['session_id'] as String,
    role: (map['role'] as String) == 'user' ? MessageRole.user : MessageRole.assistant,
    content: map['content'] as String,
    createdAt: DateTime.parse(map['created_at'] as String),
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'session_id': sessionId,
    'role': role == MessageRole.user ? 'user' : 'assistant',
    'content': content,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}
