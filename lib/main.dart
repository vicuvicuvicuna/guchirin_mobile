import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ui/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterGemma.initialize(inferenceEngines: const [LiteRtLmEngine()]);
  runApp(const GuchirinApp());
}

class GuchirinApp extends StatelessWidget {
  const GuchirinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ぐちりん',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal), useMaterial3: true),
      // Without an explicit locale, Flutter's text renderer has no signal to
      // prefer the Japanese glyph variants for shared Han (CJK) codepoints,
      // and can fall back to Chinese-style glyph shapes even on a Japanese
      // device — this fixes that by using the device's own Japanese system
      // font correctly, no bundled font asset needed.
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ja')],
      locale: const Locale('ja'),
      home: const ChatScreen(),
    );
  }
}
