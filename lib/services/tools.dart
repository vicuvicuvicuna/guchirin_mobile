import 'package:flutter_gemma/flutter_gemma.dart';

import 'search_service.dart';

/// Direct port of guchirin_dev's `backend/tools.py::WEB_SEARCH_TOOL`.
const webSearchTool = Tool(
  name: 'web_search',
  description:
      'Web検索を行い最新情報を取得する。'
      '最新ニュース、現在の情報、URL、特定の会社や統計情報、その他固有名詞（名前は指示がない場合除く）など、'
      'LLM自身の知識にない情報が必要な場合に使う。',
  parameters: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': '検索クエリ'},
    },
    'required': ['query'],
  },
);

/// Tools available to the chat model. Mirrors guchirin_dev's
/// `backend/tools.py::available_tools()`: a function (not a bare constant)
/// so future phases can grow this conditionally (e.g. only include a memory
/// tool once the memory store has entries) without touching callers.
List<Tool> availableTools() => const [webSearchTool];

/// Dispatches a tool call by name. Mirrors guchirin_dev's
/// `backend/tools.py::execute_tool()`.
Future<String> executeTool(String name, Map<String, dynamic> args) async {
  switch (name) {
    case 'web_search':
      final query = (args['query'] as String?)?.trim() ?? '';
      final results = await webSearch(query);
      final formatted = formatSearchResults(results);
      return formatted.isNotEmpty ? formatted : '検索結果が見つかりませんでした。';
    default:
      return '不明なツール: $name';
  }
}
