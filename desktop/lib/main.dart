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
        colorSchemeSeed: const Color(0xFF2B6CB0),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
