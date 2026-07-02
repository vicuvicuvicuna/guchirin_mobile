import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-device app settings (API keys, etc). Backed by
/// SharedPreferences (app-private storage) rather than baked into the
/// build, so each install can be configured independently without
/// rebuilding — required for anyone besides the original developer to use
/// their own Tavily key.
class SettingsService {
  static const _tavilyApiKeyPref = 'tavily_api_key';

  Future<String?> getTavilyApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tavilyApiKeyPref);
  }

  Future<void> setTavilyApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    if (key.isEmpty) {
      await prefs.remove(_tavilyApiKeyPref);
    } else {
      await prefs.setString(_tavilyApiKeyPref, key);
    }
  }
}
