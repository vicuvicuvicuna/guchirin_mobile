import 'dart:convert';

import 'package:http/http.dart' as http;

import 'settings_service.dart';

const _searchResultCount = 3;

// Tavily's `content` field is a much richer extract than DDG's old short
// snippets (observed 600-5000+ chars per result, 13000+ chars for 5
// results combined) — easily blows the on-device model's 4096-token
// context window (LlmService.contextWindow) in a single tool response.
// Truncate per-result to keep the total search context small.
const _bodyMaxChars = 250;

/// Searches via the Tavily Search API and returns up to [maxResults]
/// results as {title, body, href} maps. Returns an empty list on any
/// failure (including a missing/unset API key), mirroring Python's
/// web_search() fail-soft behavior. The key is read from [SettingsService]
/// (per-device local storage, configurable from the app's settings screen)
/// rather than baked into the build, so anyone installing the app can use
/// their own free-tier key without rebuilding.
///
/// Replaces an earlier DuckDuckGo-lite HTML-scraping implementation, which
/// DuckDuckGo started serving an anti-bot CAPTCHA challenge for instead of
/// results (no code fix possible — same fate hit Python's `ddgs` library
/// scraping `html.duckduckgo.com`, confirmed 2026-07-02).
Future<List<Map<String, String>>> webSearch(
  String query, {
  int maxResults = _searchResultCount,
}) async {
  final apiKey = await SettingsService().getTavilyApiKey();
  if (apiKey == null || apiKey.isEmpty) return [];
  try {
    final response = await http.post(
      Uri.parse('https://api.tavily.com/search'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({'query': query, 'max_results': maxResults}),
    );
    if (response.statusCode != 200) return [];
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final results = data['results'] as List<dynamic>? ?? [];
    return results
        .map(
          (r) => {
            'title': (r['title'] as String?) ?? '',
            'body': _truncate((r['content'] as String?) ?? ''),
            'href': (r['url'] as String?) ?? '',
          },
        )
        .where((r) => r['href']!.isNotEmpty && r['title']!.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

String _truncate(String text) =>
    text.length <= _bodyMaxChars ? text : '${text.substring(0, _bodyMaxChars)}…';

/// Formats search results into a context string for the LLM, mirroring
/// Python's format_search_results().
String formatSearchResults(List<Map<String, String>> results) {
  if (results.isEmpty) return '';
  final lines = <String>[
    '以下はWeb検索結果です。必要に応じて参考にして回答してください:\n',
  ];
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    lines.add(
      '[${i + 1}] ${r['title'] ?? ''}\n${r['body'] ?? ''}\n出典: ${r['href'] ?? ''}\n',
    );
  }
  return lines.join('\n');
}
