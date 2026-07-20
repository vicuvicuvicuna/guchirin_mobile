/// Reply-length tiers, expressed as a hard `maxOutputTokens` cap rather than
/// just a prompt hint — small on-device models don't reliably self-limit
/// length from instructions alone, so the cap is what actually keeps replies
/// short.
enum ResponseLength {
  short('short', '短め', 280),
  medium('medium', '標準', 450),
  long('long', '長め', 800);

  const ResponseLength(this.id, this.label, this.maxTokens);

  final String id;
  final String label;
  final int maxTokens;

  static ResponseLength fromId(String id) =>
      values.firstWhere((length) => length.id == id, orElse: () => medium);
}

/// Preset personas for the "口調" (tone) setting: each adds a short
/// instruction on top of LlmService's base system instruction to bias how
/// the model frames its replies, plus a default reply length, without
/// touching what it's allowed to say.
enum PersonaPreset {
  standard('standard', '標準', null, ResponseLength.medium),
  empathetic(
    'empathetic',
    '寄り添う',
    'アドバイスや解決策を急がず、まずユーザーの気持ちを受け止め、共感を言葉にしてから話してください。'
        '否定や説教はせず、味方として話を聞く姿勢を大切にしてください。',
    ResponseLength.medium,
  ),
  summarizer(
    'summarizer',
    '要約する',
    '結論を最初の一文で述べ、その後の説明は箇条書きで要点のみ簡潔にまとめてください。'
        '前置きや言い換え、装飾的な表現は省いてください。',
    ResponseLength.short,
  ),
  custom('custom', 'カスタム', null, ResponseLength.medium);

  const PersonaPreset(this.id, this.label, this.instruction, this.defaultLength);

  /// Stored in SharedPreferences to remember the user's selection.
  final String id;

  /// Shown in the persona picker UI.
  final String label;

  /// System-instruction addition for this preset, or null when the preset
  /// has no fixed text of its own ([standard]'s base instruction is enough
  /// on its own; [custom]'s text comes from the user instead).
  final String? instruction;

  /// Reply length used for this preset. Ignored for [custom], where the
  /// user picks their own [ResponseLength] instead.
  final ResponseLength defaultLength;

  static PersonaPreset fromId(String id) =>
      values.firstWhere((preset) => preset.id == id, orElse: () => standard);
}
