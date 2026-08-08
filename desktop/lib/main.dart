import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() {
  runApp(const YubiBoardApp());
}

/// THE HACK 2026 / THE WIN — YubiBoard デスクトップ（共通Flutter層）。
/// 各OSのネイティブ（複数ポインタ注入・透過オーバーレイ）は DesktopBridge の裏。
class YubiBoardApp extends StatelessWidget {
  const YubiBoardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YubiBoard Desktop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5A4696),
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFFF3FBF9),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: const Color(0xFF3F3F3F),
          displayColor: const Color(0xFF3F3F3F),
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
