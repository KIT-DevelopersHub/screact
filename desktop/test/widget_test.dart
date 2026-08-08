import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/main.dart';

void main() {
  testWidgets('app boots with one-button pairing home', (tester) async {
    await tester.pumpWidget(const YubiBoardApp());
    await tester.pump();
    // ゼロコンフィグの1ボタン画面: 「スマホ設置完了」だけが主要操作。
    expect(find.text('Screact'), findsOneWidget);
    expect(find.text('スマホ設置完了'), findsOneWidget);
    // 従来の4ステップUIは出ていない（隠されている）。
    expect(find.text('サーバ開始'), findsNothing);
    expect(find.text('Androidに入力する接続情報'), findsNothing);
  });

  testWidgets('hidden dev toggle reveals legacy panel', (tester) async {
    await tester.pumpWidget(const YubiBoardApp());
    await tester.pump();
    // 右下の隠しボタン（tune アイコン）で開発者向け画面へ。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('サーバ開始'), findsOneWidget);
    expect(find.text('Androidに入力する接続情報'), findsOneWidget);
    // 開発者向け要素は折りたたみ配下。展開して確認する。
    await tester.scrollUntilVisible(find.text('開発者向け設定'), 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('開発者向け設定'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('モックの手を流す'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('モックの手を流す'), findsOneWidget);
    // 「かんたん画面へ戻る」で1ボタン画面に戻れる。
    await tester.tap(find.text('かんたん画面へ戻る'));
    await tester.pumpAndSettle();
    expect(find.text('スマホ設置完了'), findsOneWidget);
  });
}
