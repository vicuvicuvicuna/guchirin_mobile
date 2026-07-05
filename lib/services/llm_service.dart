import 'dart:async';
import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';

/// One event from [LlmService.sendMessage]'s agent loop.
sealed class AgentEvent {}

/// A text token to append to the in-progress answer.
class AgentToken extends AgentEvent {
  AgentToken(this.text);
  final String text;
}

/// A tool is about to be executed; the caller can surface a status label.
class AgentToolCall extends AgentEvent {
  AgentToolCall(this.name, this.args);
  final String name;
  final Map<String, dynamic> args;
}

/// On-device chat model, backed by flutter_gemma's LiteRT-LM engine.
///
/// Mirrors the role `backend/llm.py` plays in guchirin_dev: install the model
/// once, then stream tokens for each turn. Unlike the backend (Ollama, one
/// HTTP call per turn), the model and chat session stay resident here, so
/// install/load only happen once per app run.
class LlmService {
  LlmService({this.tools = const [], this.toolExecutor});

  /// Tools the model may call natively (Gemma 4 SDK tool-calling). Fixed at
  /// session creation; see _ensureChatReady().
  final List<Tool> tools;

  /// Dispatches a tool call by name to its result text. Required if [tools]
  /// is non-empty.
  final Future<String> Function(String name, Map<String, dynamic> args)?
  toolExecutor;

  static const modelType = ModelType.gemma4;
  static const fileType = ModelFileType.litertlm;
  static const modelFileName = 'gemma-4-E2B-it.litertlm';
  static const modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/$modelFileName';

  // KV-cache context window and per-turn output cap. Mirrors
  // backend/config.py's CONTEXT_WINDOW / ANSWER_MAX_TOKENS, scaled down from
  // the desktop defaults (16384/1200) to leave RAM headroom on phones.
  // Raised from an initial 4096 after tool responses (web_search results)
  // routinely exceeded it even after truncation; 8192 is a middle ground —
  // watch for OOM on lower-RAM devices if raising further.
  static const contextWindow = 8192;
  static const answerMaxTokens = 800;

  // Mirrors backend/config.py's MAX_AGENT_STEPS: caps the tool-call decision
  // loop so a model that never converges on a final answer can't loop
  // forever.
  static const maxAgentSteps = 4;

  // Mirrors backend/config.py's MAX_HISTORY_MESSAGES (20), which the backend
  // replays into every request since Ollama calls are stateless. Here it's
  // replayed once when a session is opened (see resetChat below). Halved
  // versus the backend because contextWindow is already halved (8192 vs
  // 16384), and because InferenceChat's own token bookkeeping only counts
  // images and generated output, not replayed query text — its automatic
  // context-trimming safety net won't catch an oversized replay, so this has
  // to be bounded here. Starting point; tune down if replay is slow or gets
  // truncated in practice.
  static const historyReplayLimit = 10;
  static const historyReplayMaxCharsPerMessage = 1000;

  static const _systemInstruction =
      '回答は要点を絞り、必要十分な長さで簡潔に答えてください。'
      '過剰な見出し・箇条書き・表・絵文字の多用は避け、自然な文章を基本としてください。'
      '最新情報・ニュース・特定の事実・固有名詞の確認など、自分の知識だけでは'
      '自信を持って答えられない質問には、遠慮せずweb_searchツールを使って調べてから'
      '回答してください。「分かりません」「知識にありません」で済ませる前に、'
      'まずツールで調べるようにしてください。';

  InferenceModel? _model;
  InferenceChat? _chat;

  Future<bool> isInstalled() => FlutterGemma.isModelInstalled(modelFileName);

  /// Downloads the model if needed, yielding progress 0-100. No-op (empty
  /// stream) if already installed.
  Stream<int> install() {
    final controller = StreamController<int>();
    FlutterGemma.installModel(modelType: modelType, fileType: fileType)
        .fromNetwork(modelUrl)
        .withProgress((progress) => controller.add(progress))
        .install()
        .then((_) => controller.close())
        .catchError((Object e, StackTrace st) => controller.addError(e, st));
    return controller.stream;
  }

  Future<InferenceChat> _createChat() async {
    _model ??= await FlutterGemma.getActiveModel(maxTokens: contextWindow);
    return _model!.createChat(
      modelType: modelType,
      maxOutputTokens: answerMaxTokens,
      systemInstruction: _systemInstruction,
      tools: tools,
      supportsFunctionCalls: tools.isNotEmpty,
      toolChoice: ToolChoice.auto,
    );
  }

  /// Defensive fallback used by [sendMessage] in case no session was ever
  /// explicitly opened via [resetChat].
  Future<void> _ensureChatReady() async {
    _chat ??= await _createChat();
  }

  /// Discards the current conversation/KV-cache (if any) and starts a fresh
  /// one on the same loaded model — no reload of model weights. [history] is
  /// replayed turn-by-turn into the new chat (pass a session's persisted
  /// messages when switching to it; empty list for a brand-new chat).
  Future<void> resetChat({List<Message> history = const []}) async {
    _chat ??= await _createChat();
    await _chat!.clearHistory(replayHistory: history);
  }

  Future<void> stopGeneration() => _chat?.stopGeneration() ?? Future.value();

  String _callSignature(String name, Map<String, dynamic> args) {
    final sortedArgs = Map.fromEntries(
      args.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return '$name:${jsonEncode(sortedArgs)}';
  }

  List<FunctionCallResponse> _extractCalls(ModelResponse response) =>
      switch (response) {
        FunctionCallResponse() => [response],
        ParallelFunctionCallResponse(:final calls) => calls,
        _ => const [],
      };

  /// Sends [text] as a user turn and streams the assistant's reply,
  /// running the native tool-call loop (up to [maxAgentSteps] rounds) when
  /// the model requests a tool before answering.
  Stream<AgentEvent> sendMessage(String text) async* {
    await _ensureChatReady();
    final chat = _chat!;
    await chat.addQueryChunk(Message.text(text: text, isUser: true));

    final seenCalls = <String>{};

    for (var step = 0; step < maxAgentSteps; step++) {
      final calls = <FunctionCallResponse>[];
      await for (final response in chat.generateChatResponseAsync()) {
        if (response is TextResponse) {
          yield AgentToken(response.token);
        } else {
          calls.addAll(_extractCalls(response));
        }
      }

      final newCalls = calls
          .where((c) => seenCalls.add(_callSignature(c.name, c.args)))
          .toList();
      if (newCalls.isEmpty) return;

      for (final call in newCalls) {
        yield AgentToolCall(call.name, call.args);
        final result = await toolExecutor!(call.name, call.args);
        await chat.addQueryChunk(
          Message.toolResponse(toolName: call.name, response: {'result': result}),
        );
      }
    }

    // Step cap exhausted without a final answer: force one last turn and
    // surface only its text, ignoring any further tool calls, rather than
    // looping forever or erroring out.
    yield AgentToken('（ツール呼び出しが完了しませんでした。ここまでの情報で回答します）\n');
    await for (final response in chat.generateChatResponseAsync()) {
      if (response is TextResponse) {
        yield AgentToken(response.token);
      }
    }
  }

  Future<void> dispose() async {
    await _model?.close();
    _model = null;
    _chat = null;
  }
}
