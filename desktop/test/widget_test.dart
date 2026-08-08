import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/main.dart';
import 'package:thehack_overlay/platform/desktop_bridge.dart';
import 'package:thehack_overlay/ui/home_page.dart';

const _menuKey = ValueKey('desktop-header-menu');

class _AccessibilityBridge implements DesktopBridge {
  bool trusted = false;
  int requestCount = 0;

  @override
  bool get isNativeBackend => true;

  @override
  String get name => 'macos test native';

  @override
  Future<bool> accessibilityTrusted() async => trusted;

  @override
  Future<void> requestAccessibility() async {
    requestCount++;
    trusted = true;
  }

  @override
  Future<void> applyEvent(InteractionEvent e) async {}

  @override
  Future<void> setOverlayVisible(bool visible) async {}
}

Future<void> navigateFromDrawer(WidgetTester tester, String destination) async {
  await tester.tap(find.byKey(_menuKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(destination)));
  await tester.pumpAndSettle();
}

void expectInViewport(WidgetTester tester, Finder finder, Size viewport) {
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(-0.01), reason: '$finder left');
  expect(rect.top, greaterThanOrEqualTo(-0.01), reason: '$finder top');
  expect(
    rect.right,
    lessThanOrEqualTo(viewport.width + 0.01),
    reason: '$finder right',
  );
  expect(
    rect.bottom,
    lessThanOrEqualTo(viewport.height + 0.01),
    reason: '$finder bottom',
  );
}

void main() {
  testWidgets('4画面をヘッダーとドロワーから移動できる', (tester) async {
    await tester.pumpWidget(const YubiBoardApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('connection-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('server-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-status')), findsOneWidget);
    expect(find.byKey(_menuKey), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktop-header-settings')),
      findsOneWidget,
    );

    await navigateFromDrawer(tester, 'nav-calibration');
    expect(find.byKey(const ValueKey('calibration-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('calibration-start')), findsOneWidget);
    expect(find.byKey(const ValueKey('calibration-preview')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('calibration-target-image')),
      findsNothing,
      reason: '開始前の案内画面に本物のArUcoターゲットを表示しない',
    );

    await navigateFromDrawer(tester, 'nav-workspace');
    expect(find.byKey(const ValueKey('workspace-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('overlay-enter')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('desktop-header-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-save')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final viewport in const [Size(800, 600), Size(1160, 740)]) {
    testWidgets(
      '${viewport.width.toInt()}x${viewport.height.toInt()}で4画面の主要要素が収まる',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(const YubiBoardApp());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectInViewport(
          tester,
          find.byKey(const ValueKey('connection-page')),
          viewport,
        );
        expectInViewport(
          tester,
          find.byKey(const ValueKey('connection-info')),
          viewport,
        );
        expectInViewport(
          tester,
          find.byKey(const ValueKey('server-toggle')),
          viewport,
        );
        expectInViewport(
          tester,
          find.byKey(const ValueKey('pairing-status')),
          viewport,
        );
        final connectionCharacter = tester.getRect(
          find.byKey(const ValueKey('connection-character')),
        );
        expect(
          connectionCharacter.overlaps(
            tester.getRect(find.byKey(const ValueKey('server-toggle'))),
          ),
          isFalse,
          reason: '接続画面のキャラクターが開始ボタンに重ならない',
        );
        expect(
          connectionCharacter.overlaps(
            tester.getRect(find.byKey(const ValueKey('server-stop'))),
          ),
          isFalse,
          reason: '接続画面のキャラクターが停止ボタンに重ならない',
        );
        expectInViewport(tester, find.byKey(_menuKey), viewport);

        await navigateFromDrawer(tester, 'nav-calibration');
        expect(tester.takeException(), isNull);
        expectInViewport(
          tester,
          find.byKey(const ValueKey('calibration-page')),
          viewport,
        );
        expectInViewport(
          tester,
          find.byKey(const ValueKey('calibration-start')),
          viewport,
        );
        expect(
          tester
              .getRect(find.byKey(const ValueKey('calibration-character')))
              .overlaps(
                tester.getRect(find.byKey(const ValueKey('calibration-start'))),
              ),
          isFalse,
          reason: '位置合わせ画面のキャラクターが開始ボタンに重ならない',
        );

        await navigateFromDrawer(tester, 'nav-workspace');
        expect(tester.takeException(), isNull);
        expectInViewport(
          tester,
          find.byKey(const ValueKey('workspace-page')),
          viewport,
        );
        expectInViewport(
          tester,
          find.byKey(const ValueKey('overlay-enter')),
          viewport,
        );

        await navigateFromDrawer(tester, 'nav-settings');
        expect(tester.takeException(), isNull);
        expectInViewport(
          tester,
          find.byKey(const ValueKey('settings-page')),
          viewport,
        );
        expectInViewport(
          tester,
          find.byKey(const ValueKey('settings-save')),
          viewport,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets('未許可なら設定画面からアクセシビリティを要求して再確認する', (tester) async {
    if (!Platform.isMacOS) return;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final bridge = _AccessibilityBridge();

    await tester.pumpWidget(MaterialApp(home: HomePage(desktopBridge: bridge)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('desktop-header-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('accessibility-warning')), findsOneWidget);
    expectInViewport(
      tester,
      find.byKey(const ValueKey('accessibility-request')),
      const Size(800, 600),
    );
    expectInViewport(
      tester,
      find.byKey(const ValueKey('settings-save')),
      const Size(800, 600),
    );

    await tester.tap(find.byKey(const ValueKey('accessibility-request')));
    await tester.pumpAndSettle();
    expect(bridge.requestCount, 1);
    expect(find.byKey(const ValueKey('accessibility-warning')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
