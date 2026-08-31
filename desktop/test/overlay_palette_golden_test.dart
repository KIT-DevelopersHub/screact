import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/ui/color_palette.dart';
import 'package:thehack_overlay/ui/overlay_canvas.dart';

/// オーバーレイ（インク＋消しゴムの輪）＋右下の大きな色丸の見た目を1枚に
/// レンダリングした確認用ゴールデン。`flutter test --update-goldens` で
/// test/goldens/overlay_palette.png を生成する（UIスクショの代替）。
void main() {
  testWidgets('overlay + big color circle screenshot', (tester) async {
    final model = OverlayModel();

    // 1本目: 初期のペン色（青）で描く線。
    model.applyTrack(
      0,
      const InteractionEvent(InteractionKind.drawDown, Vec2(0.12, 0.30)),
    );
    for (var x = 0.14; x <= 0.45; x += 0.02) {
      model.applyTrack(
        0,
        InteractionEvent(InteractionKind.drawMove, Vec2(x, 0.30 + 0.12 * (x))),
      );
    }
    model.applyTrack(
      0,
      const InteractionEvent(InteractionKind.drawUp, Vec2(0.45, 0.36)),
    );

    // 色丸を1回押して赤へ進め、2本目を赤で描く。
    model.cyclePenColor(); // 青 → 赤
    model.applyTrack(
      1,
      const InteractionEvent(InteractionKind.drawDown, Vec2(0.55, 0.62)),
    );
    for (var x = 0.57; x <= 0.85; x += 0.02) {
      model.applyTrack(
        1,
        InteractionEvent(InteractionKind.drawMove, Vec2(x, 0.62 - 0.10 * (x))),
      );
    }
    model.applyTrack(
      1,
      const InteractionEvent(InteractionKind.drawUp, Vec2(0.85, 0.55)),
    );

    // 消しゴム（グー）の輪を表示するトラック。
    model.applyTrack(
      2,
      const InteractionEvent(InteractionKind.eraseDown, Vec2(0.40, 0.68)),
    );

    // 色丸をさらに進めて現在色を緑にした状態を見せる（赤 → 黄 → 緑）。
    model.cyclePenColor(); // 赤 → 黄
    model.cyclePenColor(); // 黄 → 緑

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(900, 560)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            width: 900,
            height: 560,
            color: const Color(0xFFEDE7F0),
            child: Stack(
              children: [
                Positioned.fill(child: OverlayCanvas(model: model)),
                Positioned(
                  right: 24,
                  bottom: 24,
                  child: ColorPalette(model: model),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(OverlayCanvas),
      matchesGoldenFile('goldens/overlay_palette.png'),
    );
  });
}
