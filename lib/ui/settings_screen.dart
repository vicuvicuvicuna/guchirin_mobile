import 'package:flutter/material.dart';

import '../models/persona.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onSaved});

  /// Called after a successful save, so the caller (chat screen) can reload
  /// the active chat with the newly saved persona.
  final VoidCallback? onSaved;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();
  final _tavilyController = TextEditingController();
  final _customPersonaController = TextEditingController();
  bool _loading = true;
  bool _saved = false;
  PersonaPreset _persona = PersonaPreset.standard;
  ResponseLength _customLength = ResponseLength.medium;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = await _settings.getTavilyApiKey();
    final persona = await _settings.getPersonaPreset();
    final customText = await _settings.getCustomPersonaText();
    final customLength = await _settings.getCustomPersonaLength();
    setState(() {
      _tavilyController.text = key ?? '';
      _persona = persona;
      _customPersonaController.text = customText;
      _customLength = customLength;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _settings.setTavilyApiKey(_tavilyController.text.trim());
    await _settings.setPersonaPreset(_persona);
    await _settings.setCustomPersonaText(_customPersonaController.text.trim());
    await _settings.setCustomPersonaLength(_customLength);
    if (!mounted) return;
    setState(() => _saved = true);
    widget.onSaved?.call();
  }

  @override
  void dispose() {
    _tavilyController.dispose();
    _customPersonaController.dispose();
    super.dispose();
  }

  Widget _buildPersonaSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ペルソナ・口調', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('返信の口調と、目安の長さを選べます。'),
        RadioGroup<PersonaPreset>(
          groupValue: _persona,
          onChanged: (value) => setState(() {
            _persona = value!;
            _saved = false;
          }),
          child: Column(
            children: PersonaPreset.values
                .map(
                  (preset) => RadioListTile<PersonaPreset>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(preset.label),
                    subtitle: preset == PersonaPreset.custom
                        ? const Text('自由記述の指示文と、長さを指定')
                        : Text('長さの目安: ${preset.defaultLength.label}'),
                    value: preset,
                  ),
                )
                .toList(),
          ),
        ),
        if (_persona == PersonaPreset.custom) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _customPersonaController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'カスタムの口調指示',
              hintText: '例: 関西弁で、テンポよくツッコミを入れながら答えて',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _saved = false),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ResponseLength>(
            segments: ResponseLength.values
                .map((length) => ButtonSegment(value: length, label: Text(length.label)))
                .toList(),
            selected: {_customLength},
            onSelectionChanged: (selection) => setState(() {
              _customLength = selection.first;
              _saved = false;
            }),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Web検索を使うには Tavily の無料APIキーが必要です。'
                    'tavily.com でアカウント作成後、取得したキー(tvly-で始まる文字列)を入力してください。',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _tavilyController,
                    decoration: const InputDecoration(
                      labelText: 'Tavily APIキー',
                      hintText: 'tvly-...',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() => _saved = false),
                  ),
                  const SizedBox(height: 24),
                  _buildPersonaSection(),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton(onPressed: _save, child: const Text('保存')),
                      if (_saved) ...[
                        const SizedBox(width: 12),
                        const Text('保存しました'),
                      ],
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}
