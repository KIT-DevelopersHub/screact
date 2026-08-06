import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/homography.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/protocol/messages.dart';

void main() {
  group('Homography', () {
    test('maps the 4 marker corners to screen corners', () {
      final h = Homography.fromMarkers(MockHand.markers().markers)!;
      // カメラ枠 0.1..0.9 の四隅が画面 0..1 の四隅へ写ること。
      final tl = h.map(const Vec2(0.1, 0.1));
      final br = h.map(const Vec2(0.9, 0.9));
      expect(tl.x, closeTo(0, 1e-6));
      expect(tl.y, closeTo(0, 1e-6));
      expect(br.x, closeTo(1, 1e-6));
      expect(br.y, closeTo(1, 1e-6));
      // 中心は中心へ。
      final c = h.map(const Vec2(0.5, 0.5));
      expect(c.x, closeTo(0.5, 1e-6));
      expect(c.y, closeTo(0.5, 1e-6));
    });
  });

  group('Protocol parsing', () {
    test('hand_frame not-detected parses safely', () {
      final f = HandFrame.fromJson({
        'messageType': 'hand_frame',
        'frameId': 5,
        'capturedAtMonotonicMs': 100,
        'hand': {'detected': false},
      });
      expect(f.detected, isFalse);
      expect(f.isValid, isTrue);
      expect(f.landmarks, isEmpty);
    });
  });

  group('InteractionEngine', () {
    test('mock frames produce pointer + press events after calibration', () {
      final engine = InteractionEngine();
      expect(engine.calibrate(MockHand.markers()), isTrue);
      expect(engine.mode, EngineMode.tracking);

      final kinds = <InteractionKind>{};
      for (var i = 0; i < 60; i++) {
        for (final e in engine.onFrame(MockHand.frame(i))) {
          kinds.add(e.kind);
        }
      }
      expect(kinds.contains(InteractionKind.pointerMove), isTrue);
      expect(
          kinds.contains(InteractionKind.pressDown) ||
              kinds.contains(InteractionKind.pressMove),
          isTrue);
    });

    test('lost tracking releases safely', () {
      final engine = InteractionEngine();
      engine.calibrate(MockHand.markers());
      engine.onFrame(MockHand.frame(25)); // pinch region → pressed
      final ev = engine.onFrame(const HandFrame(
          frameId: 99, capturedAtMonotonicMs: 0, detected: false));
      expect(ev.any((e) => e.kind == InteractionKind.release), isTrue);
    });

    test('screen coords stay within 0..1', () {
      final engine = InteractionEngine();
      engine.calibrate(MockHand.markers());
      for (var i = 0; i < 90; i++) {
        for (final e in engine.onFrame(MockHand.frame(i))) {
          expect(e.screen.x, inInclusiveRange(0, 1));
          expect(e.screen.y, inInclusiveRange(0, 1));
        }
      }
    });
  });
}
