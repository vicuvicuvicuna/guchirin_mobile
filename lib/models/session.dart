/// A single chat session (conversation). Persisted in the encrypted local
/// database; see DatabaseService/SessionRepository.
class Session {
  const Session({required this.id, required this.title, required this.createdAt});

  final String id;
  final String title;
  final DateTime createdAt;

  factory Session.fromMap(Map<String, Object?> map) => Session(
    id: map['id'] as String,
    title: map['title'] as String,
    createdAt: DateTime.parse(map['created_at'] as String),
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}
