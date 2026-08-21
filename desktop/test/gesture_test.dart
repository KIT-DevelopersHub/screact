import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/gesture_recognizer.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';

/// ジェスチャー仕様変更のテスト:
/// - 描画 = 人差し指と中指がくっつく（drawDown/drawMove）・筆点は人差し指先端
/// - OSクリック = つまむ（ピンチ）→ pressDown/pressUp（インクは引かない）
void main() {
  group('GestureRecognizer', () {
    test('2本指くっつきを検出し、drawPointは人差し指と中指の中間点', () {
      final rec = GestureRecognizer();
      final f = MockHand.at(
        frameId: 0,
        tip: const Vec2(0.5, 0.5),
        pinch: false,
        together: true,
      );
      final pose = rec.recognize(f)!;
      expect(pose.fingersTogether, isTrue);
      expect(pose.pinching, isFalse);
      // mock: indexTip=(0.5,0.5), middleTip=(0.52,0.5) → 中間点(0.51,0.5)
      expect(pose.drawPoint.x, closeTo(0.51, 1e-6));
      expect(pose.drawPoint.y, closeTo(0.5, 1e-6));
    });

    test('指が離れていれば fingersTogether は false', () {
      final rec = GestureRecognizer();
      final f = MockHand.at(
        frameId: 0,
        tip: const Vec2(0.5, 0.5),
        pinch: false,
        together: false,
      );
      expect(rec.recognize(f)!.fingersTogether, isFalse);
    });

    test('ピンチとくっつきは独立に判定される（ピンチ時は描画しない）', () {
      final rec = GestureRecognizer();
      final f = MockHand.at(
        frameId: 0,
        tip: const Vec2(0.5, 0.5),
        pinch: true,
        together: false,
      );
      final pose = rec.recognize(f)!;
      expect(pose.pinching, isTrue);
      expect(pose.fingersTogether, isFalse);
    });

    test('くっつきのヒステリシス（境界のチャタリング防止）', () {
      // onRatio<比率<offRatio の中間状態では、直前の状態を保持する。
      final rec = GestureRecognizer(
        togetherOnRatio: 0.35,
        togetherOffRatio: 0.55,
      );
      // まず確実にくっつける（ratio小）→ together=true
      rec.recognize(
        MockHand.at(
          frameId: 0,
          tip: const Vec2(0.5, 0.5),
          pinch: false,
          together: true,
        ),
      );
      // 離す（ratio大）→ together=false
      final off = rec.recognize(
        MockHand.at(
          frameId: 1,
          tip: const Vec2(0.5, 0.5),
          pinch: false,
          together: false,
        ),
      );
      expect(off!.fingersTogether, isFalse);
    });
  });

  group('InteractionEngine ジェスチャー分岐', () {
    InteractionEngine calibrated() {
      final e = InteractionEngine();
      expect(e.calibrate(MockHand.markers()), isTrue);
      return e;
    }

    test('2本指くっつきで drawDown→drawMove（インク描画・press系は出ない）', () {
      final e = calibrated();
      final kinds = <InteractionKind>{};
      for (var i = 0; i < 6; i++) {
        // 少しずつ動かしながらくっつけ続ける
        final tip = Vec2(0.4 + i * 0.02, 0.5);
        for (final ev in e.onFrame(
          MockHand.at(frameId: i, tip: tip, pinch: false, together: true),
        )) {
          kinds.add(ev.kind);
        }
      }
      expect(kinds.contains(InteractionKind.drawDown), isTrue);
      expect(kinds.contains(InteractionKind.drawMove), isTrue);
      // 描画中に OSクリック系(press*)は出ない
      expect(kinds.contains(InteractionKind.pressDown), isFalse);
      expect(kinds.contains(InteractionKind.pressMove), isFalse);
    });

    test('くっつきを解くと drawUp が出る', () {
      final e = calibrated();
      e.onFrame(
        MockHand.at(
          frameId: 0,
          tip: const Vec2(0.5, 0.5),
          pinch: false,
          together: true,
        ),
      );
      final ev = e.onFrame(
        MockHand.at(
          frameId: 1,
          tip: const Vec2(0.5, 0.5),
          pinch: false,
          together: false,
        ),
      );
      expect(ev.any((x) => x.kind == InteractionKind.drawUp), isTrue);
    });

    test('つまむ（ピンチ）で pressDown→（離すと）click＋pressUp・drawは出ない', () {
      final e = calibrated();
      final down = e.onFrame(
        MockHand.at(
          frameId: 0,
          tip: const Vec2(0.5, 0.5),
          pinch: true,
          together: false,
        ),
      );
      expect(down.any((x) => x.kind == InteractionKind.pressDown), isTrue);
      expect(down.any((x) => x.kind == InteractionKind.drawDown), isFalse);
      // 同じ位置で短時間に離す → click（＋pressUp）
      final up = e.onFrame(
        MockHand.at(
          frameId: 1,
          tip: const Vec2(0.5, 0.5),
          pinch: false,
          together: false,
        ),
      );
      expect(up.any((x) => x.kind == InteractionKind.click), isTrue);
      expect(up.any((x) => x.kind == InteractionKind.pressUp), isTrue);
    });

    test('描画中の筆点は人差し指先端（中指との中間点は使わない）', () {
      final e = calibrated();
      InteractionEvent? draw;
      for (var i = 0; i < 3; i++) {
        for (final ev in e.onFrame(
          MockHand.at(
            frameId: i,
            tip: const Vec2(0.5, 0.5),
            pinch: false,
            together: true,
          ),
        )) {
          if (ev.kind == InteractionKind.drawDown ||
              ev.kind == InteractionKind.drawMove) {
            draw = ev;
          }
        }
      }
      // 人差し指先端(0.5,0.5)→homography（0.1..0.9→0..1）で 0.5 付近。
      // 中間点(0.51)由来の 0.5125 とは異なる＝人差し指先端が使われている証拠。
      // ※トリガー条件（together=true・人差し指＋中指くっつき）は不変。
      expect(draw, isNotNull);
      expect(draw!.screen.x, closeTo(0.5, 0.02));
      expect(draw!.screen.x, lessThan(0.51));
    });
  });

  group('グッドサインでスクロール', () {
    InteractionEngine calibrated() {
      final e = InteractionEngine(smoothingEnabled: false);
      expect(e.calibrate(MockHand.markers()), isTrue);
      return e;
    }

    InteractionEvent scrollOf(List<InteractionEvent> events) => events
        .singleWhere((e) => e.kind == InteractionKind.scroll);

    test('親指だけを立てた手をグッドサインとして認識する', () {
      final rec = GestureRecognizer();
      final pose = rec.recognize(
        MockHand.goodSign(frameId: 0, thumbDir: const Vec2(0, -1)),
      )!;
      expect(pose.goodSign, isTrue);
      expect(pose.thumbExtended, isTrue);
      expect(pose.extendedFingers, 0);
      expect(pose.pinching, isFalse);
    });

    test('通常のポインタ姿勢（人差し指を立てる）はグッドサインではない', () {
      final rec = GestureRecognizer();
      final pose = rec.recognize(
        MockHand.at(frameId: 0, tip: const Vec2(0.5, 0.5), pinch: false),
      )!;
      expect(pose.goodSign, isFalse);
    });

    test('親指が上ならスクロールは上向き（delta.y<0・水平成分なし）', () {
      final e = calibrated();
      final ev = scrollOf(
        e.onFrame(MockHand.goodSign(frameId: 1, thumbDir: const Vec2(0, -1))),
      );
      expect(ev.delta.y, lessThan(0));
      expect(ev.delta.x, closeTo(0, 1e-9));
    });

    test('親指が下ならスクロールは下向き（delta.y>0）', () {
      final e = calibrated();
      final ev = scrollOf(
        e.onFrame(MockHand.goodSign(frameId: 1, thumbDir: const Vec2(0, 1))),
      );
      expect(ev.delta.y, greaterThan(0));
      expect(ev.delta.x, closeTo(0, 1e-9));
    });

    test('親指が右ならスクロールは水平（delta.x!=0・垂直成分なし）', () {
      final e = calibrated();
      final ev = scrollOf(
        e.onFrame(MockHand.goodSign(frameId: 1, thumbDir: const Vec2(1, 0))),
      );
      expect(ev.delta.x.abs(), greaterThan(0));
      expect(ev.delta.y, closeTo(0, 1e-9));
    });

    test('グッドサインは描画（drawDown）を生成しない', () {
      final e = calibrated();
      final kinds = e
          .onFrame(MockHand.goodSign(frameId: 1, thumbDir: const Vec2(0, -1)))
          .map((e) => e.kind);
      expect(kinds, contains(InteractionKind.scroll));
      expect(kinds, isNot(contains(InteractionKind.drawDown)));
    });
  });

  group('ジェスチャー個別ON/OFF', () {
    InteractionEngine calibrated({
      bool clickEnabled = true,
      bool penEnabled = true,
      bool scrollEnabled = true,
    }) {
      final e = InteractionEngine(
        smoothingEnabled: false,
        clickEnabled: clickEnabled,
        penEnabled: penEnabled,
        scrollEnabled: scrollEnabled,
      );
      expect(e.calibrate(MockHand.markers()), isTrue);
      return e;
    }

    Iterable<InteractionKind> kinds(List<InteractionEvent> events) =>
        events.map((e) => e.kind);

    test('scrollEnabled=false: グッドサインはスクロールせずポインタ移動になる', () {
      final e = calibrated(scrollEnabled: false);
      final k = kinds(
        e.onFrame(MockHand.goodSign(frameId: 1, thumbDir: const Vec2(0, -1))),
      );
      expect(k, isNot(contains(InteractionKind.scroll)));
      expect(k, contains(InteractionKind.pointerMove));
    });

    test('penEnabled=false: くっつきでも描画せずポインタ移動になる', () {
      final e = calibrated(penEnabled: false);
      final k = kinds(
        e.onFrame(
          MockHand.at(
            frameId: 1,
            tip: const Vec2(0.5, 0.5),
            pinch: false,
            together: true,
          ),
        ),
      );
      expect(k, isNot(contains(InteractionKind.drawDown)));
      expect(k, contains(InteractionKind.pointerMove));
    });

    test('clickEnabled=false: ピンチでも押下せずポインタ移動になる', () {
      final e = calibrated(clickEnabled: false);
      final k = kinds(
        e.onFrame(
          MockHand.at(
            frameId: 1,
            tip: const Vec2(0.5, 0.5),
            pinch: true,
            together: false,
          ),
        ),
      );
      expect(k, isNot(contains(InteractionKind.pressDown)));
      expect(k, contains(InteractionKind.pointerMove));
    });

    test('既定は全ジェスチャーが有効', () {
      final e = InteractionEngine();
      expect(e.clickEnabled, isTrue);
      expect(e.penEnabled, isTrue);
      expect(e.eraserEnabled, isTrue);
      expect(e.scrollEnabled, isTrue);
    });
  });
}
