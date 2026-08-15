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
