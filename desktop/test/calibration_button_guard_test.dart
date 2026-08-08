import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/calibration_config.dart';
import 'package:thehack_overlay/core/homography.dart';
import 'package:thehack_overlay/net/discovery.dart';
import 'package:thehack_overlay/ui/home_page.dart';
import 'package:thehack_overlay/ui/pairing_controller.dart';

Map<String, dynamic> calibrationMarkersMessage() {
  const insetX = CalibrationConfig.targetMarkerInsetX;
  const insetY = CalibrationConfig.targetMarkerInsetY;
  const centers = [
    [insetX, insetY],
    [1 - insetX, insetY],
    [1 - insetX, 1 - insetY],
    [insetX, 1 - insetY],
  ];
  return {
    'schemaVersion': 1,
    'messageType': 'calibration_markers',
    'capturedAtMonotonicMs': 0,
    'markers': [
      for (var i = 0; i < 4; i++)
        {
          'id': Homography.cornerMarkerIds[i],
          'center': centers[i],
          'corners': [
            [centers[i][0] - .02, centers[i][1] - .02],
            [centers[i][0] + .02, centers[i][1] - .02],
            [centers[i][0] + .02, centers[i][1] + .02],
            [centers[i][0] - .02, centers[i][1] + .02],
          ],
        },
    ],
  };
}

/// 実WebSocketサーバを画面内で動かすため、実時間で進むLive bindingを使う。
void main() {
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  List<String> mockNative({required bool enterSucceeds}) {
    final calls = <String>[];
    messenger.setMockMessageHandler('yubiboard/overlay_window', (
      message,
    ) async {
      final call = codec.decodeMethodCall(message);
      calls.add(call.method);
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
      () => messenger.setMockMessageHandler('yubiboard/overlay_window', null),
    );
    return calls;
  }

  Finder productionButton(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(FilledButton),
  );

  bool enabled(WidgetTester tester, Finder finder) =>
      (tester.widget<FilledButton>(finder)).onPressed != null;

  Future<void> settle(
    WidgetTester tester, [
    Duration wait = const Duration(milliseconds: 350),
  ]) async {
    await Future<void>.delayed(wait);
    await tester.pump();
  }

  Future<void> navigateFromDrawer(
    WidgetTester tester,
    String destination,
  ) async {
    await tester.tap(find.byKey(const ValueKey('desktop-header-menu')));
    await settle(tester);
    await tester.tap(find.byKey(ValueKey(destination)));
    await settle(tester);
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for UI state');
      }
      await settle(tester, const Duration(milliseconds: 100));
    }
  }

  testWidgets('接続開始→hello→位置合わせ→切断→停止の4画面フロー', (tester) async {
    mockNative(enterSucceeds: false);
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(MaterialApp(home: HomePage(port: port)));
    await tester.pump();

    final start = productionButton('server-toggle');
    final stop = productionButton('server-stop');
    expect(find.byKey(const ValueKey('connection-page')), findsOneWidget);
    expect(enabled(tester, start), isTrue);
    expect(enabled(tester, stop), isFalse);

    // 停止中と、サーバ稼働中でもスマホ未接続の間は位置合わせを開始できない。
    await navigateFromDrawer(tester, 'nav-calibration');
    final calibrationStart = productionButton('calibration-start');
    expect(enabled(tester, calibrationStart), isFalse);
    await navigateFromDrawer(tester, 'nav-connection');

    await tester.tap(start);
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('pairing-code')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const ValueKey('pairing-status')), findsOneWidget);
    expect(find.textContaining('スマホを検索'), findsOneWidget);
    expect(enabled(tester, start), isFalse);
    expect(enabled(tester, stop), isTrue);

    final pairingText = tester.widget<SelectableText>(
      find.byKey(const ValueKey('pairing-code')),
    );
    final code = pairingText.data!;
    expect(RegExp(r'^\d{6}$').hasMatch(code), isTrue);

    await navigateFromDrawer(tester, 'nav-calibration');
    expect(enabled(tester, calibrationStart), isFalse);
    await navigateFromDrawer(tester, 'nav-connection');

    final socket = await WebSocket.connect('ws://localhost:$port/ws/v1/input');
    addTearDown(socket.close);
    socket.listen((_) {});
    socket.add(
      jsonEncode({
        'schemaVersion': 1,
        'messageType': 'hello',
        'deviceId': 'guard-test-phone',
        'pairingToken': code,
      }),
    );

    // hello完了で位置合わせ画面へ自動遷移し、開始ボタンが有効になる。
    await waitFor(
      tester,
      () =>
          find.byKey(const ValueKey('calibration-page')).evaluate().isNotEmpty,
    );
    expect(enabled(tester, calibrationStart), isTrue);
    expect(find.byKey(const ValueKey('calibration-preview')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('calibration-target-image')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('desktop-header-menu')), findsOneWidget);

    // ネイティブの全画面突入拒否時も、ウィンドウ内ターゲットへフォールバックする。
    await tester.tap(calibrationStart);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('キャリブレーション中: スマホのカメラで'), findsOneWidget);
    expect(find.byKey(const ValueKey('calibration-cancel')), findsOneWidget);
    expect(find.byKey(const ValueKey('calibration-preview')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-header-menu')), findsNothing);
    final target = find.byKey(const ValueKey('calibration-target-image'));
    expect(target, findsOneWidget);
    final targetRect = tester.getRect(target);
    final viewSize = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(targetRect.topLeft, Offset.zero);
    expect(targetRect.size, viewSize);

    // 未校正での中止は位置合わせ画面へ戻り、同じボタンをもう一度使える。
    await tester.tap(find.byKey(const ValueKey('calibration-cancel')));
    await settle(tester);
    expect(find.byKey(const ValueKey('calibration-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('calibration-preview')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('calibration-target-image')),
      findsNothing,
    );
    expect(enabled(tester, calibrationStart), isTrue);

    await tester.tap(calibrationStart);
    await settle(tester);
    expect(
      find.byKey(const ValueKey('calibration-target-image')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calibration-cancel')));
    await settle(tester);
    expect(find.byKey(const ValueKey('calibration-page')), findsOneWidget);
    expect(enabled(tester, calibrationStart), isTrue);

    await socket.close();
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('connection-page')).evaluate().isNotEmpty,
    );
    expect(calibrationStart, findsNothing);
    await navigateFromDrawer(tester, 'nav-calibration');
    expect(enabled(tester, calibrationStart), isFalse);

    await navigateFromDrawer(tester, 'nav-connection');
    await tester.tap(stop);
    await waitFor(tester, () => !enabled(tester, stop));
    expect(enabled(tester, start), isTrue);
    expect(enabled(tester, stop), isFalse);
    expect(find.byKey(const ValueKey('pairing-code')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, const Duration(milliseconds: 100));
  });

  testWidgets('UDP検索timeout後も手動接続情報を残し、再試行で検索に戻る', (tester) async {
    mockNative(enterSucceeds: false);
    final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final discoveryPort = probe.port;
    probe.close();
    final pairing = PairingController(
      discoveryFactory:
          () => DesktopDiscovery(
            token: 'unused-test-token',
            wsPort: 1,
            discoveryPort: discoveryPort,
            broadcastAddresses: const ['127.0.0.1'],
            offerInterval: const Duration(milliseconds: 40),
          ),
      searchTimeout: const Duration(milliseconds: 220),
    );
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(
      MaterialApp(home: HomePage(port: port, pairingController: pairing)),
    );
    await tester.pump();

    await tester.tap(productionButton('server-toggle'));
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('pairing-retry')).evaluate().isNotEmpty,
    );
    expect(find.textContaining('スマホが見つかりません'), findsOneWidget);
    expect(find.byKey(const ValueKey('connection-info')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);
    expect(find.text('IPアドレス'), findsOneWidget);
    expect(find.text('IPポート'), findsOneWidget);
    expect(enabled(tester, productionButton('server-toggle')), isTrue);
    expect(enabled(tester, productionButton('server-stop')), isTrue);

    await tester.tap(find.byKey(const ValueKey('pairing-retry')));
    await settle(tester, const Duration(milliseconds: 40));
    expect(find.textContaining('スマホを検索'), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);

    await tester.tap(productionButton('server-stop'));
    await settle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('再位置合わせの中止はtrackingへ戻りワークスペースを再表示する', (tester) async {
    mockNative(enterSucceeds: false);
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(MaterialApp(home: HomePage(port: port)));
    await tester.pump();

    await tester.tap(productionButton('server-toggle'));
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('pairing-code')).evaluate().isNotEmpty,
    );
    final code =
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('pairing-code')))
            .data!;

    final received = <Map<String, dynamic>>[];
    final socket = await WebSocket.connect('ws://localhost:$port/ws/v1/input');
    addTearDown(socket.close);
    socket.listen((data) {
      received.add(jsonDecode(data as String) as Map<String, dynamic>);
    });
    socket.add(
      jsonEncode({
        'schemaVersion': 1,
        'messageType': 'hello',
        'deviceId': 'recalibration-test-phone',
        'pairingToken': code,
      }),
    );
    await waitFor(
      tester,
      () =>
          find.byKey(const ValueKey('calibration-page')).evaluate().isNotEmpty,
    );

    final calibrationStart = productionButton('calibration-start');
    await tester.tap(calibrationStart);
    await settle(tester);
    socket.add(jsonEncode(calibrationMarkersMessage()));
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('workspace-page')).evaluate().isNotEmpty,
    );

    await navigateFromDrawer(tester, 'nav-calibration');
    expect(enabled(tester, calibrationStart), isTrue);
    final trackingBeforeCancel =
        received.where((message) {
          return message['messageType'] == 'control_message' &&
              message['command'] == 'set_mode' &&
              message['mode'] == 'tracking';
        }).length;

    await tester.tap(calibrationStart);
    await settle(tester);
    expect(
      find.byKey(const ValueKey('calibration-target-image')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calibration-cancel')));
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('workspace-page')).evaluate().isNotEmpty,
    );
    await waitFor(
      tester,
      () =>
          received.where((message) {
            return message['messageType'] == 'control_message' &&
                message['command'] == 'set_mode' &&
                message['mode'] == 'tracking';
          }).length >
          trackingBeforeCancel,
    );
    expect(
      find.byKey(const ValueKey('calibration-target-image')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('desktop-header-menu')), findsOneWidget);

    await socket.close();
    await settle(tester);
    await navigateFromDrawer(tester, 'nav-connection');
    await tester.tap(productionButton('server-stop'));
    await settle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, const Duration(milliseconds: 100));
  });

  testWidgets('スマホ切断時は描画オーバーレイを閉じて再検索画面へ戻る', (tester) async {
    final nativeCalls = mockNative(enterSucceeds: true);
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(MaterialApp(home: HomePage(port: port)));
    await tester.pump();

    await tester.tap(productionButton('server-toggle'));
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('pairing-code')).evaluate().isNotEmpty,
    );
    final code =
        tester
            .widget<SelectableText>(find.byKey(const ValueKey('pairing-code')))
            .data!;
    final socket = await WebSocket.connect('ws://localhost:$port/ws/v1/input');
    socket.listen((_) {});
    socket.add(
      jsonEncode({
        'schemaVersion': 1,
        'messageType': 'hello',
        'deviceId': 'overlay-disconnect-phone',
        'pairingToken': code,
      }),
    );
    await waitFor(
      tester,
      () =>
          find.byKey(const ValueKey('calibration-page')).evaluate().isNotEmpty,
    );

    await navigateFromDrawer(tester, 'nav-workspace');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('overlay-enter')),
        matching: find.byType(FilledButton),
      ),
    );
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('workspace-page')).evaluate().isEmpty,
    );
    expect(nativeCalls, contains('enterOverlay'));

    await socket.close();
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('connection-page')).evaluate().isNotEmpty,
    );
    expect(nativeCalls, contains('exitOverlay'));
    expect(find.byKey(const ValueKey('server-toggle')), findsOneWidget);

    await tester.tap(productionButton('server-stop'));
    await settle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, const Duration(milliseconds: 100));
  });

  testWidgets('サーバ開始途中でdisposeしても例外にならない', (tester) async {
    mockNative(enterSucceeds: false);
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(MaterialApp(home: HomePage(port: port)));
    await tester.pump();

    await tester.tap(productionButton('server-toggle'));
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('サーバ停止途中でdisposeしても例外にならない', (tester) async {
    mockNative(enterSucceeds: false);
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(MaterialApp(home: HomePage(port: port)));
    await tester.pump();

    await tester.tap(productionButton('server-toggle'));
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('pairing-code')).evaluate().isNotEmpty,
    );
    await tester.tap(productionButton('server-stop'));
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('診断画面のモード切替はスマホ未接続時に無効', (tester) async {
    mockNative(enterSucceeds: true);
    final port = 20000 + Random().nextInt(20000);
    await tester.pumpWidget(MaterialApp(home: HomePage(port: port)));
    await tester.pump();

    await tester.tap(productionButton('server-toggle'));
    await waitFor(
      tester,
      () => find.byKey(const ValueKey('pairing-code')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const ValueKey('desktop-header-menu')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('nav-diagnostics')));
    await settle(tester);

    Finder modeButton(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(OutlinedButton),
    );
    final calibration = modeButton('位置合わせ');
    final tracking = modeButton('トラッキング');
    expect(tester.widget<OutlinedButton>(calibration).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(tracking).onPressed, isNull);

    await tester.tap(find.text('閉じる'));
    await settle(tester);
    await tester.tap(productionButton('server-stop'));
    await settle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, const Duration(milliseconds: 100));
  });
}
