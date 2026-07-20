/// A single chat session (conversation). Persisted in the encrypted local
/// database; see DatabaseService/SessionRepository.
class Session {
  const Session({
    required this.id,
    required this.title,
    required this.createdAt,
    this.summary = '',
    this.summarizedThrough = 0,
  });

  final String id;
  final String title;
  final DateTime createdAt;

  /// Rolling recap of turns folded out of the live replay window by
  /// context compaction (see LlmService.summarize); empty until compaction
  /// has run once for this session.
  final String summary;

  /// How many of this session's messages (in created_at order) are already
  /// covered by [summary]. Messages beyond this index are replayed raw.
  final int summarizedThrough;

  factory Session.fromMap(Map<String, Object?> map) => Session(
    id: map['id'] as String,
    title: map['title'] as String,
    createdAt: DateTime.parse(map['created_at'] as String),
    summary: map['summary'] as String? ?? '',
    summarizedThrough: map['summarized_through'] as int? ?? 0,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'created_at': createdAt.toUtc().toIso8601String(),
    'summary': summary,
    'summarized_through': summarizedThrough,
  };
}
