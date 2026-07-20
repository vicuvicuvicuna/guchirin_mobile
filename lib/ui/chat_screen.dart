import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart' show Message;

import '../models/chat_message_record.dart';
import '../models/session.dart';
import '../services/database_service.dart';
import '../services/llm_service.dart';
import '../services/session_repository.dart';
import '../services/settings_service.dart';
import '../services/tools.dart';
import 'settings_screen.dart';

/// Reply text is considered probably cut off mid-thought if it doesn't end
/// on one of these — flutter_gemma exposes no finish-reason, so this is a
/// heuristic stand-in for "did the maxOutputTokens cap bite".
const _sentenceEnders = {'。', '！', '？', '」', '』', '.', '!', '?', '"', "'", ')', '）'};

class _ChatMessage {
  _ChatMessage({required this.isUser, required this.text});

  final bool isUser;
  String text;
}

enum _ModelStatus { checking, needsDownload, downloading, loadingModel, ready, error }

/// Label followed by an animated 0-3 dot ellipsis (e.g. "読み込み中" -> "読み込み中..."),
/// so long-running steps with no numeric progress (model weight load, chat
/// warm-up) still read as "in progress" rather than a frozen screen.
class _LoadingDots extends StatefulWidget {
  const _LoadingDots({required this.label});

  final String label;

  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots> {
  late final Timer _timer;
  int _dots = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => setState(() => _dots = (_dots + 1) % 4),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('${widget.label}${'.' * _dots}');
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _llm = LlmService(tools: availableTools(), toolExecutor: executeTool);
  final _repo = SessionRepository(DatabaseService.instance);
  final _settings = SettingsService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  List<Session> _sessions = [];
  String? _currentSessionId;

  _ModelStatus _status = _ModelStatus.checking;
  int _downloadProgress = 0;
  String? _errorMessage;
  bool _isGenerating = false;
  bool _isSwitchingSession = false;
  bool _searchMode = false;

  @override
  void initState() {
    super.initState();
    _checkModel();
  }

  Future<void> _checkModel() async {
    final installed = await _llm.isInstalled();
    if (!installed) {
      setState(() => _status = _ModelStatus.needsDownload);
      return;
    }
    setState(() => _status = _ModelStatus.loadingModel);
    await _loadPersonaSettings();
    await _initSessions();
    if (mounted) setState(() => _status = _ModelStatus.ready);
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
      setState(() => _status = _ModelStatus.loadingModel);
      await _loadPersonaSettings();
      await _initSessions();
      if (mounted) setState(() => _status = _ModelStatus.ready);
    } catch (e) {
      setState(() {
        _status = _ModelStatus.error;
        _errorMessage = 'モデルのダウンロードに失敗しました: $e';
      });
    }
  }

  /// Pulls the persona/tone and reply-length settings into [_llm]. Only
  /// takes effect on the next chat creation, so callers that need it to
  /// apply to the *current* session must also reset the chat (see
  /// [_reloadPersona]).
  Future<void> _loadPersonaSettings() async {
    _llm.personaInstruction = await _settings.getPersonaInstruction();
    _llm.answerMaxTokens = await _settings.getPersonaMaxTokens();
  }

  /// Called when the settings screen saves a persona change: reloads the
  /// setting and rebuilds the current session's chat (fresh KV-cache,
  /// history replayed) so the new tone/length applies immediately instead of
  /// waiting for the next session switch.
  Future<void> _reloadPersona() async {
    await _loadPersonaSettings();
    final sessionId = _currentSessionId;
    if (sessionId == null || _isGenerating) return;
    final session = await _repo.getSession(sessionId);
    final records = await _repo.listMessages(sessionId);
    if (!mounted || session == null) return;
    final unsummarized = records.length > session.summarizedThrough
        ? records.sublist(session.summarizedThrough)
        : const <ChatMessageRecord>[];
    await _llm.resetChat(history: _buildReplayHistory(unsummarized, summary: session.summary));
  }

  Future<void> _initSessions() async {
    await _refreshSessions();
    if (_sessions.isEmpty) {
      await _newSession();
    } else {
      await _openSession(_sessions.first);
    }
  }

  Future<void> _refreshSessions() async {
    final sessions = await _repo.listSessions();
    if (!mounted) return;
    setState(() => _sessions = sessions);
  }

  Future<void> _newSession() async {
    final session = await _repo.createSession();
    await _refreshSessions();
    await _openSession(session);
  }

  /// How many unsummarized messages beyond [LlmService.historyReplayLimit]
  /// can accumulate before [_maybeCompactContext] folds the oldest of them
  /// into the session's rolling summary. Keeps compaction infrequent (about
  /// every 5 exchanges) rather than re-summarizing on every turn.
  static const _compactionSlack = 10;

  /// Bounds how much of a session's *unsummarized* tail gets replayed into a
  /// fresh InferenceChat: last [LlmService.historyReplayLimit] messages, each
  /// truncated to [LlmService.historyReplayMaxCharsPerMessage] chars, with
  /// [summary] (if any) injected as a leading context turn so older folded
  /// history isn't simply lost. See llm_service.dart for why bounding this
  /// can't rely on the library's own context-trimming (it drops silently,
  /// FIFO, with no summarization).
  List<Message> _buildReplayHistory(List<ChatMessageRecord> records, {String summary = ''}) {
    final recent = records.length > LlmService.historyReplayLimit
        ? records.sublist(records.length - LlmService.historyReplayLimit)
        : records;
    final messages = recent.map((record) {
      final content = record.content.length > LlmService.historyReplayMaxCharsPerMessage
          ? record.content.substring(0, LlmService.historyReplayMaxCharsPerMessage)
          : record.content;
      return Message.text(text: content, isUser: record.role == MessageRole.user);
    }).toList();
    if (summary.isNotEmpty) {
      messages.insert(
        0,
        Message.text(
          text: '(これまでの会話の要約。今後の応答ではこの内容を踏まえること)\n$summary',
          isUser: true,
        ),
      );
    }
    return messages;
  }

  /// Runs after a turn is persisted: if enough raw messages have piled up
  /// beyond the live replay window, folds the oldest of them into the
  /// session's rolling summary (via [LlmService.summarize]) and rebuilds the
  /// live chat context from summary + remaining recent turns. Fails soft —
  /// a summarization error just leaves compaction to retry next turn,
  /// falling back on flutter_gemma's own (cruder) trimming in the meantime.
  Future<void> _maybeCompactContext(String sessionId) async {
    try {
      final session = await _repo.getSession(sessionId);
      if (session == null) return;
      final records = await _repo.listMessages(sessionId);
      final unsummarizedCount = records.length - session.summarizedThrough;
      if (unsummarizedCount <= LlmService.historyReplayLimit + _compactionSlack) return;

      final newSummarizedThrough = records.length - LlmService.historyReplayLimit;
      final toFold = records.sublist(session.summarizedThrough, newSummarizedThrough);
      final newSummary = await _llm.summarize(
        previousSummary: session.summary,
        turns: toFold.map((r) => (isUser: r.role == MessageRole.user, text: r.content)).toList(),
      );
      await _repo.updateSummary(sessionId, summary: newSummary, summarizedThrough: newSummarizedThrough);
      unawaited(_refreshSessions());

      if (!mounted || sessionId != _currentSessionId) return;
      final recent = records.sublist(newSummarizedThrough);
      await _llm.resetChat(history: _buildReplayHistory(recent, summary: newSummary));
    } catch (_) {
      // Fail soft — see doc comment above.
    }
  }

  Future<void> _openSession(Session session) async {
    if (_isGenerating) {
      await _llm.stopGeneration();
    }
    setState(() => _isSwitchingSession = true);
    // Re-fetched rather than trusting `session.summary`/`summarizedThrough`:
    // the caller's copy (from the cached _sessions list) may be stale if a
    // compaction pass updated it since the last _refreshSessions().
    final fresh = await _repo.getSession(session.id) ?? session;
    final records = await _repo.listMessages(session.id);
    if (!mounted) return;
    setState(() {
      _currentSessionId = session.id;
      _messages
        ..clear()
        ..addAll(records.map((r) => _ChatMessage(isUser: r.role == MessageRole.user, text: r.content)));
    });
    _scrollToBottom();
    try {
      final unsummarized = records.length > fresh.summarizedThrough
          ? records.sublist(fresh.summarizedThrough)
          : const <ChatMessageRecord>[];
      await _llm.resetChat(history: _buildReplayHistory(unsummarized, summary: fresh.summary));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('チャットの初期化に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSwitchingSession = false);
    }
  }

  Future<void> _renameSession(Session session) async {
    final controller = TextEditingController(text: session.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('名前を変更'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty) return;
    await _repo.renameSession(session.id, newTitle);
    await _refreshSessions();
  }

  Future<void> _deleteSession(Session session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('セッションを削除'),
        content: Text('「${session.title}」を削除しますか?この操作は取り消せません。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('削除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.deleteSession(session.id);
    await _refreshSessions();
    if (session.id == _currentSessionId) {
      if (_sessions.isNotEmpty) {
        await _openSession(_sessions.first);
      } else {
        await _newSession();
      }
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    final sessionId = _currentSessionId;
    if (text.isEmpty || _isGenerating || sessionId == null) return;
    _textController.clear();

    await _repo.maybeAutoTitle(sessionId, text);
    await _repo.addMessage(sessionId, isUser: true, content: text);
    unawaited(_refreshSessions());

    setState(() {
      _messages.add(_ChatMessage(isUser: true, text: text));
      _messages.add(_ChatMessage(isUser: false, text: '考え中...'));
      _isGenerating = true;
    });
    _scrollToBottom();

    var startedAnswer = false;
    var succeeded = false;
    try {
      await for (final event in _llm.sendMessage(text, searchMode: _searchMode)) {
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
      succeeded = true;
      if (startedAnswer) {
        final trimmed = _messages.last.text.trimRight();
        if (trimmed.isNotEmpty && !_sentenceEnders.contains(trimmed[trimmed.length - 1])) {
          setState(() => _messages.last.text = '$trimmed…');
        }
      }
    } catch (e) {
      setState(() => _messages.last.text = '[エラー] 応答生成に失敗しました: $e');
    }

    // Only persist if a real answer was streamed (startedAnswer), not a
    // leftover "考え中..."/"検索中..." status string from a stream that
    // ended without ever producing a token (step-cap exhaustion, error, or
    // the session being switched away from mid-generation).
    if (succeeded && startedAnswer && _messages.last.text.isNotEmpty) {
      await _repo.addMessage(sessionId, isUser: false, content: _messages.last.text);
      unawaited(_refreshSessions());
      // Kept under _isGenerating (input stays disabled) since compaction
      // may rebuild _llm's live chat/KV-cache via resetChat — letting the
      // user send another message concurrently would race with that.
      await _maybeCompactContext(sessionId);
    }
    if (mounted) setState(() => _isGenerating = false);
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

  String _formatSessionDate(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
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
              MaterialPageRoute(builder: (_) => SettingsScreen(onSaved: _reloadPersona)),
            ),
          ),
        ],
      ),
      drawer: _status == _ModelStatus.ready ? _buildSessionDrawer() : null,
      body: switch (_status) {
        _ModelStatus.checking => _buildFullScreenLoading('起動しています'),
        _ModelStatus.needsDownload => _buildDownloadPrompt(),
        _ModelStatus.downloading => _buildDownloadProgress(),
        _ModelStatus.loadingModel => _buildFullScreenLoading('モデルを読み込んでいます'),
        _ModelStatus.error => _buildError(),
        _ModelStatus.ready => _buildChat(),
      },
    );
  }

  Widget _buildSessionDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新しいチャット'),
              onTap: () {
                Navigator.pop(context);
                _newSession();
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  final isActive = session.id == _currentSessionId;
                  return ListTile(
                    selected: isActive,
                    title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_formatSessionDate(session.createdAt)),
                    onTap: () {
                      Navigator.pop(context);
                      if (!isActive) _openSession(session);
                    },
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'rename') _renameSession(session);
                        if (value == 'delete') _deleteSession(session);
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'rename', child: Text('名前を変更')),
                        PopupMenuItem(value: 'delete', child: Text('削除')),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullScreenLoading(String label) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            _LoadingDots(label: label),
          ],
        ),
      ),
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
        if (_isSwitchingSession) const LinearProgressIndicator(minHeight: 2),
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
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _searchMode,
                    visualDensity: VisualDensity.compact,
                    onChanged: (value) => setState(() => _searchMode = value ?? false),
                  ),
                  const Text('検索する'),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
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
                    enabled: !_isGenerating && !_isSwitchingSession,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: (_isGenerating || _isSwitchingSession) ? null : _send,
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
