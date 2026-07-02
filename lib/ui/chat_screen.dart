import 'package:flutter/material.dart';

import '../services/llm_service.dart';
import '../services/tools.dart';
import 'settings_screen.dart';

class _ChatMessage {
  _ChatMessage({required this.isUser, required this.text});

  final bool isUser;
  String text;
}

enum _ModelStatus { checking, needsDownload, downloading, ready, error }

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _llm = LlmService(tools: availableTools(), toolExecutor: executeTool);
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];

  _ModelStatus _status = _ModelStatus.checking;
  int _downloadProgress = 0;
  String? _errorMessage;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _checkModel();
  }

  Future<void> _checkModel() async {
    final installed = await _llm.isInstalled();
    setState(() {
      _status = installed ? _ModelStatus.ready : _ModelStatus.needsDownload;
    });
  }

  Future<void> _downloadModel() async {
    setState(() {
      _status = _ModelStatus.downloading;
      _downloadProgress = 0;
      _errorMessage = null;
    });
    try {
      await for (final progress in _llm.install()) {
        setState(() => _downloadProgress = progress);
      }
      setState(() => _status = _ModelStatus.ready);
    } catch (e) {
      setState(() {
        _status = _ModelStatus.error;
        _errorMessage = 'モデルのダウンロードに失敗しました: $e';
      });
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isGenerating) return;
    _textController.clear();

    setState(() {
      _messages.add(_ChatMessage(isUser: true, text: text));
      _messages.add(_ChatMessage(isUser: false, text: '考え中...'));
      _isGenerating = true;
    });
    _scrollToBottom();

    try {
      var startedAnswer = false;
      await for (final event in _llm.sendMessage(text)) {
        switch (event) {
          case AgentToken(:final text):
            setState(() {
              if (!startedAnswer) {
                _messages.last.text = '';
                startedAnswer = true;
              }
              _messages.last.text += text;
            });
          case AgentToolCall(:final name, :final args):
            startedAnswer = false;
            final query = args['query']?.toString();
            setState(() {
              _messages.last.text = (name == 'web_search' && query != null && query.isNotEmpty)
                  ? '「$query」を検索中...'
                  : '検索中...';
            });
        }
        _scrollToBottom();
      }
    } catch (e) {
      setState(() => _messages.last.text = '[エラー] 応答生成に失敗しました: $e');
    } finally {
      setState(() => _isGenerating = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _llm.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ぐちりん'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: switch (_status) {
        _ModelStatus.checking => const Center(child: CircularProgressIndicator()),
        _ModelStatus.needsDownload => _buildDownloadPrompt(),
        _ModelStatus.downloading => _buildDownloadProgress(),
        _ModelStatus.error => _buildError(),
        _ModelStatus.ready => _buildChat(),
      },
    );
  }

  Widget _buildDownloadPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'チャットモデル(Gemma 4 E2B, 約2.4GB)を端末にダウンロードします。\n'
              'Wi-Fi環境での実行を推奨します。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _downloadModel, child: const Text('ダウンロード開始')),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadProgress() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: _downloadProgress / 100),
            const SizedBox(height: 12),
            Text('ダウンロード中... $_downloadProgress%'),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_errorMessage ?? 'エラーが発生しました', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _downloadModel, child: const Text('再試行')),
          ],
        ),
      ),
    );
  }

  Widget _buildChat() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final message = _messages[index];
              return Align(
                alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                  decoration: BoxDecoration(
                    color: message.isUser
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(message.text.isEmpty ? '...' : message.text),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: '愚痴を入力...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                    enabled: !_isGenerating,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _isGenerating ? null : _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
