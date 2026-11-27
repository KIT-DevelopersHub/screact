import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/ui/edge_palette.dart';
import 'package:thehack_overlay/ui/edge_palette_layout.dart';
import 'package:thehack_overlay/ui/home_page.dart';
import 'package:thehack_overlay/ui/overlay_canvas.dart';

const _screen = Size(960, 540);
const _paletteKey = ValueKey('overlay-edge-palette');

Widget _host(OverlayModel model, {required bool show}) => MediaQuery(
  data: const MediaQueryData(size: _screen),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(
        key: const ValueKey('golden-root'),
        child: Container(
          width: _screen.width,
          height: _screen.height,
          color: const Color(0xFFEDE7F0),
          child: OverlayWithEdgePalette(model: model, showEdgePalette: show),
        ),
      ),
    ),
  ),
);

EdgePalettePainter _painter(WidgetTester tester) {
  final paints = tester.widgetList<CustomPaint>(
    find.descendant(
      of: find.byKey(_paletteKey),
      matching: find.byType(CustomPaint),
    ),
  );
  return paints.map((p) => p.painter).whereType<EdgePalettePainter>().single;
}

void main() {
  setUp(() {});

  Future<void> pumpHost(
    WidgetTester tester,
    OverlayModel model, {
    bool show = true,
  }) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(model, show: show));
  }

  test('既定では画面端パレットを表示する（推奨案）', () {
    expect(HomePage.defaultShowEdgePalette, isTrue);
  });

  testWidgets('オーバーレイに画面端パレットが表示され、入力は透過する', (tester) async {
    final model = OverlayModel();
    await pumpHost(tester, model);

    expect(find.byType(OverlayCanvas), findsOneWidget);
    expect(find.byKey(_paletteKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(_paletteKey),
        matching: find.byType(IgnorePointer),
      ),
      findsOneWidget,
    );

    // 描画はヒット判定と同じレイアウト（画面サイズから計算したもの）を使う。
    final painter = _painter(tester);
    final expected = EdgePaletteLayout.compute(screenSize: _screen);
    expect(painter.layout.panelRect, expected.panelRect);
    expect(
      painter.layout.swatches.map((s) => s.rect).toList(),
      expected.swatches.map((s) => s.rect).toList(),
    );
    expect(painter.selectedSlot, isNull);
  });

  testWidgets('表示の切り替えでパレットが消える（インクの描画は残る）', (tester) async {
    final model = OverlayModel();
    await pumpHost(tester, model);
    expect(find.byKey(_paletteKey), findsOneWidget);

    await tester.pumpWidget(_host(model, show: false));
    expect(find.byKey(_paletteKey), findsNothing);
    expect(find.byType(OverlayCanvas), findsOneWidget);

    await tester.pumpWidget(_host(model, show: true));
    expect(find.byKey(_paletteKey), findsOneWidget);
  });

  testWidgets('選択中の色とカーソルが乗った色を painter へ渡す', (tester) async {
    final model = OverlayModel();
    await pumpHost(tester, model);

    model.selectColorSlot(2);
    await tester.pump();
    expect(_painter(tester).selectedSlot, 2);

    // スウォッチ 1 の中心へカーソルを置くと、そのスウォッチを強調する。
    final layout = _painter(tester).layout;
    final c = layout.toNormalizedRect(layout.swatches[1].rect).center;
    model.applyTrack(
      0,
      InteractionEvent(InteractionKind.pointerMove, Vec2(c.dx, c.dy)),
    );
    await tester.pump();
    expect(_painter(tester).hoveredSlots, {1});

    // 同じ色をもう一度選ぶと選択解除（トラック別自動色）になり、枠も消える。
    model.selectColorSlot(2);
    await tester.pump();
    expect(_painter(tester).selectedSlot, isNull);
  });

  testWidgets('golden: 画面端パレット（選択中の枠とカーソルの強調）', (tester) async {
    final model = OverlayModel();
    model.applyTrack(
      0,
      const InteractionEvent(InteractionKind.drawDown, Vec2(0.15, 0.40)),
    );
    for (var x = 0.17; x <= 0.55; x += 0.02) {
      model.applyTrack(
        0,
        InteractionEvent(InteractionKind.drawMove, Vec2(x, 0.40 + 0.1 * x)),
      );
    }
    model.applyTrack(
      0,
      const InteractionEvent(InteractionKind.drawUp, Vec2(0.55, 0.455)),
    );
    model.selectColorSlot(1);

    await pumpHost(tester, model);
    final layout = _painter(tester).layout;
    final c = layout.toNormalizedRect(layout.swatches[3].rect).center;
    model.applyTrack(
      1,
      InteractionEvent(InteractionKind.pointerMove, Vec2(c.dx, c.dy)),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('golden-root')),
      matchesGoldenFile('goldens/edge_palette.png'),
    );
  });
}
