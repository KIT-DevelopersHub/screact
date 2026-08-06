import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/ui/home_page.dart';

/// クラッシュ回帰（未接続まわりの「スマホ設置完了」フロー）と、
/// 接続状態によるボタン活性制御の検証。
///
/// 実WebSocketサーバを画面内で動かすため LiveTestWidgetsFlutterBinding
/// （実時間）を使う。既定の fake-async バインディングでは、テスト内で
/// 起動したサーバのハンドシェイクが進まずデッドロックする。
void main() {
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  void mockNative({required bool enterSucceeds}) {
    messenger.setMockMessageHandler('yubiboard/overlay_window', (msg) async {
      final call = codec.decodeMethodCall(msg);
      switch (call.method) {
        case 'isAvailable':
          return codec.encodeSuccessEnvelope(true);
        case 'enterOverlay':
          return codec.encodeSuccessEnvelope(enterSucceeds);
        case 'exitOverlay':
          return codec.encodeSuccessEnvelope(null);
      }
      return null;
    });
    addTearDown(
        () => messenger.setMockMessageHandler('yubiboard/overlay_window', null));
  }

  // FilledButton.icon は FilledButton のサブタイプを生成するため、
  // byType の完全一致ではなく is 判定で拾う。
  Finder buttonFinder(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      );

  Future<void> settle(WidgetTester tester,
      [Duration wait = const Duration(milliseconds: 300)]) async {
    await Future<void>.delayed(wait); // 実時間（Liveバインディング）
    await tester.pump();
  }

  bool enabled(WidgetTester tester, Finder f) =>
      (tester.widget(f) as FilledButton).onPressed != null;

  // Liveバインディングはドラッグでのスクロールが不安定なため、
  // パネルの ListView を jumpTo で直接動かして対象を組み立てる。
  Future<void> jump(WidgetTester tester, double offset) async {
    final st = tester.state<ScrollableState>(find.byType(Scrollable).first);
    st.position.jumpTo(offset.clamp(0, st.position.maxScrollExtent));
    await tester.pump();
  }

  // 対象が組み立てられるまで少しずつスクロールする（パネルの長さに依存しない）。
  Future<void> jumpUntil(WidgetTester tester, Finder f) async {
    final st = tester.state<ScrollableState>(find.byType(Scrollable).first);
    var off = 0.0;
    while (f.evaluate().isEmpty && off <= st.position.maxScrollExtent) {
      st.position.jumpTo(off);
      await tester.pump();
      off += 250;
    }
  }

  testWidgets('スマホ未接続では設置完了ボタン無効・接続で有効・オーバーレイ失敗でも例外なし',
      (tester) async {
    mockNative(enterSucceeds: false); // macOSフルスクリーン中の拒否と同じ応答
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(MaterialApp(home: HomePage(port: port)));
    await tester.pump();
    final placed = buttonFinder('スマホ設置完了');

    // 1. サーバ停止中: 無効
    await jumpUntil(tester, find.text('スマホ設置完了'));
    expect(enabled(tester, placed), isFalse, reason: 'サーバ停止中は押せない');

    // 2. サーバ開始（スマホ未接続）: まだ無効
    await jump(tester, 0);
    await tester.tap(buttonFinder('サーバ開始'));
    await settle(tester);
    await jumpUntil(tester, find.text('スマホ設置完了'));
    expect(enabled(tester, placed), isFalse, reason: '未接続では押せない');
    expect(find.textContaining('スマホ未接続です'), findsOneWidget);
    await jump(tester, 0); // 接続情報カード（コード表示）へ戻る

    // 3. スマホが接続（hello 完了）: 有効になる
    // 6桁コードは左パネルに表示された実値を読んで使う（表示＝照合値のE2E）。
    final code = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .firstWhere((t) => RegExp(r'^\d{6}$').hasMatch(t));
    final ws = await WebSocket.connect('ws://localhost:$port/ws/v1/input');
    addTearDown(() => ws.close());
    ws.listen((_) {});
    ws.add(jsonEncode({
      'schemaVersion': 1,
      'messageType': 'hello',
      'deviceId': 'guard-test-phone',
      'pairingToken': code,
    }));
    await settle(tester);
    await jumpUntil(tester, find.text('スマホ設置完了'));
    expect(enabled(tester, placed), isTrue, reason: '接続後は押せる');

    // 4. 押下: ネイティブ enterOverlay が false（フルスクリーン拒否相当）でも
    //    例外なくウィンドウ内表示へフォールバックする（クラッシュ回帰）。
    await tester.tap(placed);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('キャリブレーション中: スマホのカメラで'), findsOneWidget,
        reason: 'オーバーレイに入れない時はウィンドウ内で画像を表示する');

    // 5. 切断でボタンが自動的に無効へ戻る
    await ws.close();
    await settle(tester);
    await tester.tap(find.text('中止')); // フローを中止してから活性状態を確認
    await tester.pump();
    await jumpUntil(tester, find.text('スマホ設置完了'));
    expect(enabled(tester, placed), isFalse, reason: '切断後は再び押せない');

    // 後始末: サーバ停止してから破棄
    await jump(tester, 0);
    await tester.tap(buttonFinder('サーバ停止'));
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await settle(tester, const Duration(milliseconds: 100));
  });

  testWidgets('モード切替ボタンも未接続時は無効', (tester) async {
    mockNative(enterSucceeds: true);
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(MaterialApp(home: HomePage(port: port)));
    await tester.pump();

    final calib = find.ancestor(
      of: find.text('位置合わせ'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );
    await jumpUntil(tester, find.text('位置合わせ'));
    expect((tester.widget(calib) as OutlinedButton).onPressed, isNull);

    await jump(tester, 0); // 先頭（接続セクション）へ
    await tester.tap(buttonFinder('サーバ開始'));
    await settle(tester);
    await jumpUntil(tester, find.text('位置合わせ'));
    expect((tester.widget(calib) as OutlinedButton).onPressed, isNull,
        reason: 'サーバ稼働中でも未接続なら無効');

    await jump(tester, 0);
    await tester.tap(buttonFinder('サーバ停止'));
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await settle(tester, const Duration(milliseconds: 100));
  });
}
