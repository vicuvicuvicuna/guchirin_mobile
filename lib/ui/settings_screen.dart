import 'package:flutter/material.dart';

import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();
  final _tavilyController = TextEditingController();
  bool _loading = true;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = await _settings.getTavilyApiKey();
    setState(() {
      _tavilyController.text = key ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _settings.setTavilyApiKey(_tavilyController.text.trim());
    if (!mounted) return;
    setState(() => _saved = true);
  }

  @override
  void dispose() {
    _tavilyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
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
