import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/main.dart';
import 'package:thehack_overlay/platform/overlay_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  /// ネイティブ(Swift)側の応答をモックする。呼ばれたメソッド名を記録する。
  List<String> mockNative({bool available = true}) {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(OverlayWindowController.channel, (call) async {
      calls.add(call.method);
      if (!available) throw MissingPluginException();
      switch (call.method) {
        case 'isAvailable':
          return true;
        case 'enterOverlay':
          return true;
        case 'exitOverlay':
          return null;
      }
      return null;
    });
    return calls;
  }

  /// ネイティブ→Flutter の呼び出し（メニューバー/ホットキー）を注入する。
  Future<void> pushNativeCall(String method) async {
    await messenger.handlePlatformMessage(
      OverlayWindowController.channel.name,
      codec.encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(OverlayWindowController.channel, null);
  });

  group('OverlayWindowController', () {
    test('probe→enter→exit がネイティブへ委譲される', () async {
      final calls = mockNative();
      final c = OverlayWindowController();
      expect(await c.probe(), isTrue);
      expect(await c.enter(), isTrue);
      await c.exit();
      expect(calls, ['isAvailable', 'enterOverlay', 'exitOverlay']);
    });

    test('ネイティブ未接続なら enter/exit は no-op（劣化動作）', () async {
      final calls = mockNative(available: false);
      final c = OverlayWindowController();
      expect(await c.probe(), isFalse);
      expect(c.isAvailable, isFalse);
      expect(await c.enter(), isFalse);
      await c.exit();
      // probe の isAvailable だけが飛び、enter/exit はチャネルに乗らない
      expect(calls, ['isAvailable']);
    });

    test('ネイティブ側の脱出/突入通知でコールバックが呼ばれる', () async {
      mockNative();
      var exited = 0;
      var entered = 0;
      OverlayWindowController(
        onExited: () => exited++,
        onEntered: () => entered++,
      );
      await pushNativeCall('overlayExited');
      await pushNativeCall('overlayEntered');
      expect(exited, 1);
      expect(entered, 1);
    });
  });

  group('HomePage オーバーレイモード', () {
    testWidgets('突入で操作パネルが消え、解除で戻る', (tester) async {
      mockNative();
      await tester.pumpWidget(const YubiBoardApp());
      await tester.pump();
      // 既定は1ボタン画面。従来パネルは隠しトグルで開発者向け画面へ。
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pump();
      // パネルが長くなったためリスト内までスクロールして確認する。
      await tester.scrollUntilVisible(
          find.text('オーバーレイ表示'), 80,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('オーバーレイ表示'), findsOneWidget);

      // ホットキー相当: ネイティブから overlayEntered
      await pushNativeCall('overlayEntered');
      await tester.pump();
      expect(find.text('Screact'), findsNothing);
      expect(find.text('オーバーレイ表示'), findsNothing);

      // メニューバー相当: ネイティブから overlayExited
      await pushNativeCall('overlayExited');
      await tester.pump();
      expect(find.text('Screact'), findsOneWidget);
    });

    testWidgets('ボタン押下で enterOverlay がネイティブへ飛ぶ', (tester) async {
      final calls = mockNative();
      await tester.pumpWidget(const YubiBoardApp());
      await tester.pump();
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pump();
      await tester.scrollUntilVisible(
          find.text('オーバーレイ表示'), 80,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.text('オーバーレイ表示'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('オーバーレイ表示'));
      await tester.pump();
      expect(calls, contains('enterOverlay'));
      // オーバーレイモードに切り替わり、パネルは消えている
      expect(find.text('Screact'), findsNothing);
    });
  });
}
