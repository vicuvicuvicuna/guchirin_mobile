import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

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
      home: const ChatScreen(),
    );
  }
}
