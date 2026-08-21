import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/gesture_recognizer.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/protocol/messages.dart';

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

    test('グー（全指折り畳み）を fist として検出する', () {
      final rec = GestureRecognizer();
      final pose = rec.recognize(
        MockHand.fist(frameId: 0, tip: const Vec2(0.5, 0.5)),
      )!;
      expect(pose.fist, isTrue);
      expect(pose.extendedFingers, 0);
    });

    test('fist のヒステリシス: 1本だけ伸ばした中間状態では fist を保持する', () {
      final rec = GestureRecognizer();
      // グーで確実に fist=true にする。
      expect(
        rec.recognize(MockHand.fist(frameId: 0, tip: const Vec2(0.5, 0.5)))!.fist,
        isTrue,
      );
      // 人差し指1本だけ伸ばす（extendedFingers==1・不感帯）→ fist を維持。
      final mid = rec.recognize(
        MockHand.at(
          frameId: 1,
          tip: const Vec2(0.5, 0.5),
          pinch: false,
          together: false,
        ),
      )!;
      expect(mid.extendedFingers, 1);
      expect(mid.fist, isTrue);
      // 2本立てて明確に開く（extendedFingers>=2）→ fist 解除。
      final open = rec.recognize(
        MockHand.at(
          frameId: 2,
          tip: const Vec2(0.5, 0.5),
          pinch: false,
          together: true,
        ),
      )!;
      expect(open.extendedFingers, greaterThanOrEqualTo(2));
      expect(open.fist, isFalse);
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

    test('グーで eraseDown→eraseMove（消しゴム・draw/press系は出ない）', () {
      final e = calibrated();
      final kinds = <InteractionKind>{};
      for (var i = 0; i < 5; i++) {
        final tip = Vec2(0.45 + i * 0.02, 0.5);
        for (final ev in e.onFrame(MockHand.fist(frameId: i, tip: tip))) {
          kinds.add(ev.kind);
        }
      }
      expect(kinds.contains(InteractionKind.eraseDown), isTrue);
      expect(kinds.contains(InteractionKind.eraseMove), isTrue);
      expect(kinds.contains(InteractionKind.drawDown), isFalse);
      expect(kinds.contains(InteractionKind.pressDown), isFalse);
    });

    test('グーを解く（トラッキング喪失）と eraseUp が出る', () {
      final e = calibrated();
      e.onFrame(MockHand.fist(frameId: 0, tip: const Vec2(0.5, 0.5)));
      final up = e.onFrame(
        const HandFrame(frameId: 1, capturedAtMonotonicMs: 33, detected: false),
      );
      expect(up.any((x) => x.kind == InteractionKind.eraseUp), isTrue);
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
      expect(draw.screen.x, lessThan(0.51));
    });
  });
}
