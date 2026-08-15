import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/gesture_recognizer.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/protocol/messages.dart';

HandFrame frameWithPinchRatio(int frameId, double ratio, {double x = 0.5}) {
  final frame = MockHand.at(frameId: frameId, tip: Vec2(x, 0.5), pinch: false);
  final landmarks = [...frame.landmarks];
  // MockHandの手スケールは wrist→indexMcp = 0.13。
  landmarks[HandFrame.thumbTip] = Landmark(x - ratio * 0.13, 0.5, 0);
  return HandFrame(
    frameId: frameId,
    capturedAtMonotonicMs: frameId * 33,
    detected: true,
    handedness: 'RIGHT',
    landmarks: landmarks,
  );
}

InteractionEvent pointerEvent(InteractionEngine engine, HandFrame frame) =>
    engine
        .onFrame(frame)
        .singleWhere((event) => event.kind == InteractionKind.pointerMove);

void main() {
  group('recognitionSensitivity', () {
    test('既定値は従来のピンチON/OFF比率を保つ', () {
      final recognizer = GestureRecognizer();

      expect(recognizer.recognitionSensitivity, 0.5);
      expect(recognizer.pinchOnRatio, closeTo(0.40, 1e-12));
      expect(recognizer.pinchOffRatio, closeTo(0.60, 1e-12));
    });

    test('高感度では同じ指間距離をピンチとして認識する', () {
      final recognizer = GestureRecognizer();
      final frame = frameWithPinchRatio(0, 0.50);

      expect(recognizer.recognize(frame)!.pinching, isFalse);
      recognizer.recognitionSensitivity = 1;
      expect(recognizer.recognize(frame)!.pinching, isTrue);
    });

    test('感度変更時に以前のピンチ状態を持ち越さない', () {
      final recognizer = GestureRecognizer(recognitionSensitivity: 1);
      expect(
        recognizer.recognize(frameWithPinchRatio(0, 0.50))!.pinching,
        isTrue,
      );

      recognizer.recognitionSensitivity = 0;
      expect(
        recognizer.recognize(frameWithPinchRatio(1, 0.30))!.pinching,
        isFalse,
      );
    });

    test('押下中の感度変更後も次フレームで安全にpressUpへ遷移する', () {
      final engine = InteractionEngine(mode: EngineMode.tracking);
      engine.recognitionSensitivity = 1;
      final down = engine.onFrame(frameWithPinchRatio(0, 0.50));
      expect(
        down.any((event) => event.kind == InteractionKind.pressDown),
        isTrue,
      );

      engine.recognitionSensitivity = 0;
      final released = engine.onFrame(frameWithPinchRatio(1, 0.30));
      expect(
        released.any((event) => event.kind == InteractionKind.pressUp),
        isTrue,
      );
    });

    test('0..1の範囲外と非有限値を拒否する', () {
      final recognizer = GestureRecognizer();

      expect(() => recognizer.recognitionSensitivity = -0.01, throwsRangeError);
      expect(() => recognizer.recognitionSensitivity = 1.01, throwsRangeError);
      expect(
        () => recognizer.recognitionSensitivity = double.nan,
        throwsRangeError,
      );
    });
  });

  group('smoothingEnabled', () {
    test('既定で有効、無効時は入力座標をそのまま出力する', () {
      final engine = InteractionEngine(mode: EngineMode.tracking);
      expect(engine.smoothingEnabled, isTrue);

      pointerEvent(
        engine,
        MockHand.at(frameId: 0, tip: const Vec2(0.1, 0.5), pinch: false),
      );
      final smoothed = pointerEvent(
        engine,
        MockHand.at(frameId: 1, tip: const Vec2(0.9, 0.5), pinch: false),
      );
      expect(smoothed.screen.x, lessThan(0.9));

      engine.smoothingEnabled = false;
      final raw = pointerEvent(
        engine,
        MockHand.at(frameId: 2, tip: const Vec2(0.7, 0.5), pinch: false),
      );
      expect(raw.screen.x, closeTo(0.7, 1e-12));
      expect(raw.screen.y, closeTo(0.5, 1e-12));
    });

    test('再有効化時は変更前のフィルタ履歴を持ち越さない', () {
      final engine = InteractionEngine(
        mode: EngineMode.tracking,
        smoothingEnabled: false,
      );
      pointerEvent(
        engine,
        MockHand.at(frameId: 0, tip: const Vec2(0.1, 0.5), pinch: false),
      );

      engine.smoothingEnabled = true;
      final firstFiltered = pointerEvent(
        engine,
        MockHand.at(frameId: 1, tip: const Vec2(0.8, 0.5), pinch: false),
      );
      expect(firstFiltered.screen.x, closeTo(0.8, 1e-12));
    });
  });
}
