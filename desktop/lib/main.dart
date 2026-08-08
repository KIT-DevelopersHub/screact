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
    const seed = Color(0xFF2B6CB0);
    return MaterialApp(
      title: 'YubiBoard Desktop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: seed,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 42),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            textStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            textStyle:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        dividerTheme: const DividerThemeData(space: 1, thickness: 1),
      ),
      home: const HomePage(),
    );
  }
}
