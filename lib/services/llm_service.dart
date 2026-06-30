import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';

/// On-device chat model, backed by flutter_gemma's LiteRT-LM engine.
///
/// Mirrors the role `backend/llm.py` plays in guchirin_dev: install the model
/// once, then stream tokens for each turn. Unlike the backend (Ollama, one
/// HTTP call per turn), the model and chat session stay resident here, so
/// install/load only happen once per app run.
class LlmService {
  static const modelType = ModelType.gemma4;
  static const fileType = ModelFileType.litertlm;
  static const modelFileName = 'gemma-4-E2B-it.litertlm';
  static const modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/$modelFileName';

  // KV-cache context window and per-turn output cap. Mirrors
  // backend/config.py's CONTEXT_WINDOW / ANSWER_MAX_TOKENS, scaled down from
  // the desktop defaults (16384/1200) to leave more RAM headroom on phones.
  static const contextWindow = 4096;
  static const answerMaxTokens = 800;

  static const _systemInstruction =
      '回答は要点を絞り、必要十分な長さで簡潔に答えてください。'
      '過剰な見出し・箇条書き・表・絵文字の多用は避け、自然な文章を基本としてください。';

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

  Future<void> _ensureChatReady() async {
    if (_chat != null) return;
    _model = await FlutterGemma.getActiveModel(maxTokens: contextWindow);
    _chat = await _model!.createChat(
      modelType: modelType,
      maxOutputTokens: answerMaxTokens,
      systemInstruction: _systemInstruction,
    );
  }

  /// Sends [text] as a user turn and streams the assistant's reply
  /// token-by-token.
  Stream<String> sendMessage(String text) async* {
    await _ensureChatReady();
    final chat = _chat!;
    await chat.addQueryChunk(Message.text(text: text, isUser: true));
    await for (final response in chat.generateChatResponseAsync()) {
      if (response is TextResponse) {
        yield response.token;
      }
    }
  }

  Future<void> dispose() async {
    await _model?.close();
    _model = null;
    _chat = null;
  }
}
