import 'dart:async';

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
  List<String> mockNative({bool available = true, Future<bool>? enterResult}) {
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
          return enterResult ?? true;
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

    test('enter応答待ちのexitは遅れて成功したオーバーレイも閉じる', () async {
      final enterResult = Completer<bool>();
      final calls = mockNative(enterResult: enterResult.future);
      final controller = OverlayWindowController();
      expect(await controller.probe(), isTrue);

      final entering = controller.enter();
      await Future<void>.delayed(Duration.zero);
      expect(calls, contains('enterOverlay'));
      await controller.exit();
      final exitsBeforeCompletion =
          calls.where((method) => method == 'exitOverlay').length;

      enterResult.complete(true);
      await entering;
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((method) => method == 'exitOverlay').length,
        greaterThan(exitsBeforeCompletion),
        reason: '遅れたenter成功後にもexitを再送して透明窓を残さない',
      );
      controller.dispose();
    });

    test('enter応答待ちのdisposeは遅れて成功したオーバーレイを閉じる', () async {
      final enterResult = Completer<bool>();
      final calls = mockNative(enterResult: enterResult.future);
      final controller = OverlayWindowController();
      expect(await controller.probe(), isTrue);

      final entering = controller.enter();
      await Future<void>.delayed(Duration.zero);
      expect(calls, contains('enterOverlay'));
      controller.dispose();
      enterResult.complete(true);
      await entering;
      await Future<void>.delayed(Duration.zero);

      expect(
        calls.last,
        'exitOverlay',
        reason: 'dispose後にenterが成功してもネイティブ窓を必ず復帰する',
      );
    });
  });

  group('HomePage オーバーレイモード', () {
    testWidgets('未接続では再表示操作を無効化しnative突入通知も閉じる', (tester) async {
      final calls = mockNative();
      await tester.pumpWidget(const YubiBoardApp());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pairing-status')), findsOneWidget);
      await navigateToWorkspace(tester);
      final button = overlayButton();
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);

      await pushNativeCall('overlayEntered');
      await tester.pump();
      expect(find.byKey(const ValueKey('workspace-page')), findsOneWidget);
      expect(calls, contains('exitOverlay'));
      expect(calls, isNot(contains('enterOverlay')));

      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-header-menu')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('nav-overlay-enter')))
            .enabled,
        isFalse,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}
