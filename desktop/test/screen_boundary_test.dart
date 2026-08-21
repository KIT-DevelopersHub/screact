import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/protocol/messages.dart';

InteractionEngine _engine() =>
    InteractionEngine(mode: EngineMode.tracking, smoothingEnabled: false);

HandFrame _hand(
  int frameId,
  Vec2 tip, {
  bool pinch = false,
  bool together = false,
}) => MockHand.at(frameId: frameId, tip: tip, pinch: pinch, together: together);

HandFrame _withLandmark(HandFrame source, int index, Vec2 point) {
  final landmarks = [...source.landmarks];
  landmarks[index] = Landmark(point.x, point.y, 0);
  return HandFrame(
    frameId: source.frameId,
    capturedAtMonotonicMs: source.capturedAtMonotonicMs,
    detected: source.detected,
    handedness: source.handedness,
    landmarks: landmarks,
  );
}

HandFrame _scrollHand(int frameId, Vec2 tip) {
  final source = _hand(frameId, tip);
  return _withLandmark(source, HandFrame.middleTip, Vec2(tip.x + 0.12, tip.y));
}

Iterable<InteractionKind> _kinds(List<InteractionEvent> events) =>
    events.map((event) => event.kind);

void main() {
  group('InteractionEngine 画面境界', () {
    test('画面外の人差し指は操作を生成せずpointerExitだけを通知する', () {
      for (final tip in const [
        Vec2(-0.01, 0.5),
        Vec2(1.01, 0.5),
        Vec2(0.5, -0.01),
        Vec2(0.5, 1.01),
      ]) {
        final events = _engine().onFrame(_hand(1, tip, pinch: true));
        expect(_kinds(events), [InteractionKind.pointerExit]);
      }
    });

    test('0と1を含む四辺は画面内として操作できる', () {
      for (final tip in const [
        Vec2(0, 0.5),
        Vec2(1, 0.5),
        Vec2(0.5, 0),
        Vec2(0.5, 1),
      ]) {
        final events = _engine().onFrame(_hand(1, tip));
        expect(_kinds(events), contains(InteractionKind.pointerMove));
        expect(_kinds(events), isNot(contains(InteractionKind.pointerExit)));
      }
    });

    test('押下中の画面外遷移は最後の有効点でclickなし解除する', () {
      final engine = _engine();
      final down = engine.onFrame(_hand(1, const Vec2(0.4, 0.5), pinch: true));
      expect(_kinds(down), contains(InteractionKind.pressDown));

      final exit = engine.onFrame(
        _hand(2, const Vec2(-0.05, 0.5), pinch: true),
      );
      expect(
        _kinds(exit),
        containsAll([InteractionKind.pressUp, InteractionKind.pointerExit]),
      );
      expect(_kinds(exit), isNot(contains(InteractionKind.click)));
      final up = exit.singleWhere(
        (event) => event.kind == InteractionKind.pressUp,
      );
      expect(up.screen.x, closeTo(0.4, 1e-9));
      expect(up.screen.y, closeTo(0.5, 1e-9));
    });

    test('描画中の画面外遷移は最後の有効点で線を閉じる', () {
      final engine = _engine();
      final down = engine.onFrame(
        _hand(1, const Vec2(0.4, 0.5), together: true),
      );
      final start = down.singleWhere(
        (event) => event.kind == InteractionKind.drawDown,
      );

      final exit = engine.onFrame(
        _hand(2, const Vec2(-0.05, 0.5), together: true),
      );
      final up = exit.singleWhere(
        (event) => event.kind == InteractionKind.drawUp,
      );
      expect(up.screen.x, closeTo(start.screen.x, 1e-9));
      expect(up.screen.y, closeTo(start.screen.y, 1e-9));
      expect(_kinds(exit), contains(InteractionKind.pointerExit));
      expect(exit.any((event) => event.screen.x == 0), isFalse);
    });

    test('再入場は2フレーム待ち、保持中のピンチでは再押下しない', () {
      final engine = _engine();
      engine.onFrame(_hand(1, const Vec2(0.4, 0.5), pinch: true));
      engine.onFrame(_hand(2, const Vec2(-0.05, 0.5), pinch: true));

      expect(
        engine.onFrame(_hand(3, const Vec2(0.4, 0.5), pinch: true)),
        isEmpty,
      );
      final stable = engine.onFrame(
        _hand(4, const Vec2(0.4, 0.5), pinch: true),
      );
      expect(_kinds(stable), isNot(contains(InteractionKind.pressDown)));

      engine.onFrame(_hand(5, const Vec2(0.4, 0.5)));
      final repinch = engine.onFrame(
        _hand(6, const Vec2(0.4, 0.5), pinch: true),
      );
      expect(_kinds(repinch), contains(InteractionKind.pressDown));
    });

    test('人差し指が内側で描画中点だけ外側なら人差し指を筆点にする', () {
      final engine = _engine();
      final source = _hand(1, const Vec2(0.99, 0.5), together: true);
      final hand = _withLandmark(
        source,
        HandFrame.middleTip,
        const Vec2(1.03, 0.5),
      );
      final draw = engine
          .onFrame(hand)
          .singleWhere((event) => event.kind == InteractionKind.drawDown);
      expect(draw.screen.x, closeTo(0.99, 1e-9));
      expect(draw.screen.y, closeTo(0.5, 1e-9));
    });

    test('画面外でスクロール差分を生成せず、再入場後はアンカーを作り直す', () {
      final engine = _engine();
      expect(engine.onFrame(_scrollHand(1, const Vec2(0.4, 0.5))), isEmpty);
      final moving = engine.onFrame(_scrollHand(2, const Vec2(0.45, 0.5)));
      expect(_kinds(moving), contains(InteractionKind.scroll));

      final exit = engine.onFrame(_scrollHand(3, const Vec2(-0.05, 0.5)));
      expect(_kinds(exit), [InteractionKind.pointerExit]);
      expect(engine.onFrame(_scrollHand(4, const Vec2(0.6, 0.5))), isEmpty);
      expect(engine.onFrame(_scrollHand(5, const Vec2(0.6, 0.5))), isEmpty);
      final resumed = engine.onFrame(_scrollHand(6, const Vec2(0.62, 0.5)));
      expect(_kinds(resumed), contains(InteractionKind.scroll));
    });
  });
}
