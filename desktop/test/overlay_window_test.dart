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
    messenger.setMockMethodCallHandler(OverlayWindowController.channel, (
      call,
    ) async {
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

  Future<void> navigateToWorkspace(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('desktop-header-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-workspace')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-page')), findsOneWidget);
  }

  Finder overlayButton() => find.descendant(
    of: find.byKey(const ValueKey('overlay-enter')),
    matching: find.byType(FilledButton),
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(OverlayWindowController.channel, null);
  });

  group('OverlayWindowController', () {
    test('probe→enter→exit がネイティブへ委譲される', () async {
      final calls = mockNative();
      final controller = OverlayWindowController();
      expect(await controller.probe(), isTrue);
      expect(await controller.enter(), isTrue);
      await controller.exit();
      expect(calls, ['isAvailable', 'enterOverlay', 'exitOverlay']);
    });

    test('ネイティブ未接続なら enter/exit は no-op（劣化動作）', () async {
      final calls = mockNative(available: false);
      final controller = OverlayWindowController();
      expect(await controller.probe(), isFalse);
      expect(controller.isAvailable, isFalse);
      expect(await controller.enter(), isFalse);
      await controller.exit();
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
    testWidgets('突入通知で操作画面が消え、解除通知でワークスペースへ戻る', (tester) async {
      mockNative();
      await tester.pumpWidget(const YubiBoardApp());
      await tester.pumpAndSettle();
      await navigateToWorkspace(tester);
      expect(find.byKey(const ValueKey('overlay-enter')), findsOneWidget);

      await pushNativeCall('overlayEntered');
      await tester.pump();
      expect(find.byKey(const ValueKey('workspace-page')), findsNothing);
      expect(find.byKey(const ValueKey('connection-page')), findsNothing);

      await pushNativeCall('overlayExited');
      await tester.pump();
      expect(find.byKey(const ValueKey('workspace-page')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('ワークスペースのボタンでenterOverlayがネイティブへ飛ぶ', (tester) async {
      final calls = mockNative();
      await tester.pumpWidget(const YubiBoardApp());
      await tester.pumpAndSettle();
      await navigateToWorkspace(tester);

      expect(overlayButton(), findsOneWidget);
      await tester.tap(overlayButton());
      await tester.pump();
      expect(calls, contains('enterOverlay'));
      expect(find.byKey(const ValueKey('workspace-page')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}
