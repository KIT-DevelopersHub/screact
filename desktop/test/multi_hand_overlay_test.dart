import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/ui/overlay_canvas.dart';

import 'fixtures/two_hand_fixtures.dart';

List<Vec2> _asVec(List<List<double>> lm) => [
  for (final p in lm) Vec2(p[0], p[1]),
];

void main() {
  test('trackIdがパレット周期分離れていても2トラックは別色になる', () {
    final model = OverlayModel();
    model.showSkeletons({
      1: _asVec(hand7Landmarks),
      5: _asVec(hand12Landmarks),
    });
    final first = OverlayCanvas.colorForSlot(model.track(1)!.colorSlot);
    final second = OverlayCanvas.colorForSlot(model.track(5)!.colorSlot);
    expect(first, isNot(second));
  });

  test('pointerExitはカーソルだけ隠し、検出中の骨格を保持する', () {
    final model = OverlayModel();
    model.showSkeletons({7: _asVec(hand7Landmarks)});
    model.applyTrack(
      7,
      const InteractionEvent(InteractionKind.pointerMove, Vec2(0.3, 0.4)),
    );

    model.applyTrack(
      7,
      const InteractionEvent(InteractionKind.pointerExit, Vec2(0.3, 0.4)),
    );

    expect(model.track(7), isNotNull);
    expect(model.track(7)!.cursor, isNull);
    expect(model.track(7)!.skeleton, isNotNull);
  });

  testWidgets('OverlayModel は2骨格＋2カーソルを別トラックとして保持する', (tester) async {
    final model = OverlayModel();
    model.showSkeletons({
      7: _asVec(hand7Landmarks),
      12: _asVec(hand12Landmarks),
    });
    model.applyTrackEvents({
      7: [
        const InteractionEvent(InteractionKind.pointerMove, Vec2(0.27, 0.31)),
      ],
      12: [const InteractionEvent(InteractionKind.pressDown, Vec2(0.73, 0.31))],
    });

    expect(model.trackIds.toSet(), {7, 12});
    expect(model.track(7)!.skeleton!.length, 21);
    expect(model.track(12)!.skeleton!.length, 21);
    expect(model.track(12)!.pressed, isTrue);
    expect(model.track(7)!.pressed, isFalse);

    // 片手（12）が消える → 12 の骨格/カーソルが消え、7 は残る。
    model.showSkeletons({7: _asVec(hand7Landmarks)});
    model.applyTrack(
      12,
      const InteractionEvent(InteractionKind.release, Vec2(0, 0)),
    );
    expect(model.trackIds.toSet(), {7});
  });

  test('InkStroke.pathFor は点数・サイズ不変ならPathをキャッシュする', () {
    final stroke = InkStroke([
      const Vec2(0.1, 0.1),
      const Vec2(0.2, 0.2),
      const Vec2(0.3, 0.1),
    ]);
    const size = Size(640, 360);
    final first = stroke.pathFor(size);
    // 同一サイズ・同一点数なら同じPathインスタンスを返す（再構築しない）。
    expect(identical(stroke.pathFor(size), first), isTrue);

    // サイズが変われば作り直す。
    expect(identical(stroke.pathFor(const Size(800, 600)), first), isFalse);

    // 点が増えれば作り直す（描画中ストローク）。
    final beforeGrow = stroke.pathFor(size);
    stroke.points.add(const Vec2(0.4, 0.2));
    expect(identical(stroke.pathFor(size), beforeGrow), isFalse);
  });

  test('インク履歴は上限を超えると古い完了ストロークから捨てる', () {
    final model = OverlayModel();
    // 上限(240)を超える完了ストロークを作る（drawDown→drawUp）。
    for (var i = 0; i < 320; i++) {
      final x = 0.1 + (i % 50) * 0.01;
      model.applyTrack(
        7,
        InteractionEvent(InteractionKind.drawDown, Vec2(x, 0.5)),
      );
      model.applyTrack(
        7,
        InteractionEvent(InteractionKind.drawUp, Vec2(x, 0.5)),
      );
    }
    expect(model.strokes.length, lessThanOrEqualTo(240));

    // 描画中（未drawUp）のストロークは上限超過でも捨てない。
    model.applyTrack(
      7,
      const InteractionEvent(InteractionKind.drawDown, Vec2(0.9, 0.9)),
    );
    final active = model.strokes.last;
    for (var i = 0; i < 400; i++) {
      // 別トラックで新規ストロークを量産してもactiveは残る。
      model.applyTrack(
        3,
        InteractionEvent(InteractionKind.drawDown, Vec2(0.2, 0.01 * (i % 90))),
      );
      model.applyTrack(
        3,
        InteractionEvent(InteractionKind.drawUp, Vec2(0.2, 0.01 * (i % 90))),
      );
    }
    expect(model.strokes.contains(active), isTrue);
    expect(model.strokes.length, lessThanOrEqualTo(240));
  });

  testWidgets('2骨格を別色で同時描画（ゴールデン）', (tester) async {
    final model = OverlayModel();
    model.showSkeletons({
      7: _asVec(hand7Landmarks),
      12: _asVec(hand12Landmarks),
    });
    model.applyTrackEvents({
      7: [
        const InteractionEvent(InteractionKind.pointerMove, Vec2(0.27, 0.31)),
      ],
      12: [const InteractionEvent(InteractionKind.pressDown, Vec2(0.73, 0.31))],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: SizedBox(
              width: 640,
              height: 360,
              child: RepaintBoundary(
                child: ColoredBox(
                  color: Colors.white,
                  child: OverlayCanvas(model: model),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(OverlayCanvas),
      matchesGoldenFile('goldens/two_hand_skeletons.png'),
    );
  });
}
