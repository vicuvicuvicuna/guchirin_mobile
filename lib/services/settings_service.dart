import 'package:shared_preferences/shared_preferences.dart';

import '../models/persona.dart';

/// Local, per-device app settings (API keys, etc). Backed by
/// SharedPreferences (app-private storage) rather than baked into the
/// build, so each install can be configured independently without
/// rebuilding — required for anyone besides the original developer to use
/// their own Tavily key.
class SettingsService {
  static const _tavilyApiKeyPref = 'tavily_api_key';
  static const _personaIdPref = 'persona_id';
  static const _customPersonaTextPref = 'custom_persona_text';
  static const _customPersonaLengthPref = 'custom_persona_length';

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

  Future<PersonaPreset> getPersonaPreset() async {
    final prefs = await SharedPreferences.getInstance();
    return PersonaPreset.fromId(prefs.getString(_personaIdPref) ?? PersonaPreset.standard.id);
  }

  Future<void> setPersonaPreset(PersonaPreset preset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_personaIdPref, preset.id);
  }

  Future<String> getCustomPersonaText() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_customPersonaTextPref) ?? '';
  }

  Future<void> setCustomPersonaText(String text) async {
    final prefs = await SharedPreferences.getInstance();
    if (text.isEmpty) {
      await prefs.remove(_customPersonaTextPref);
    } else {
      await prefs.setString(_customPersonaTextPref, text);
    }
  }

  Future<ResponseLength> getCustomPersonaLength() async {
    final prefs = await SharedPreferences.getInstance();
    return ResponseLength.fromId(prefs.getString(_customPersonaLengthPref) ?? ResponseLength.medium.id);
  }

  Future<void> setCustomPersonaLength(ResponseLength length) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customPersonaLengthPref, length.id);
  }

  /// The tone instruction to append to LlmService's base system
  /// instruction for the currently selected persona (empty string for
  /// [PersonaPreset.standard], which relies on the base instruction alone).
  Future<String> getPersonaInstruction() async {
    final preset = await getPersonaPreset();
    if (preset == PersonaPreset.custom) return getCustomPersonaText();
    return preset.instruction ?? '';
  }

  /// The reply-length token cap for the currently selected persona.
  Future<int> getPersonaMaxTokens() async {
    final preset = await getPersonaPreset();
    if (preset == PersonaPreset.custom) {
      return (await getCustomPersonaLength()).maxTokens;
    }
    return preset.defaultLength.maxTokens;
  }
}
