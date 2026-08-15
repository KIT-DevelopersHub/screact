import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/gesture_recognizer.dart';
import 'package:thehack_overlay/core/homography.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/net/input_server.dart';
import 'package:thehack_overlay/protocol/messages.dart';

/// 斜め下・やや左から見たスライド四隅（凸台形・カメラ正規化）。
const tiltedQuad = [
  Vec2(0.18, 0.20), // TL
  Vec2(0.84, 0.12), // TR
  Vec2(0.95, 0.80), // BR
  Vec2(0.08, 0.68), // BL
];

/// スライド座標(0..1)→傾いたカメラ四隅への順方向ホモグラフィ（合成データ用）。
Homography slideToCam(List<Vec2> quad) =>
    Homography.fromCorrespondences(const [
      Vec2(0, 0),
      Vec2(1, 0),
      Vec2(1, 1),
      Vec2(0, 1),
    ], quad)!;

/// 親指-人差し指の距離比率を指定した合成フレーム（ヒステリシス検証用）。
HandFrame frameWithPinchRatio(int frameId, double ratio) {
  const tip = Vec2(0.5, 0.5);
  final f = MockHand.at(frameId: frameId, tip: tip, pinch: false);
  // scale = wrist(0.5,0.75)->mcp(0.5,0.62) = 0.13
  final lm = [...f.landmarks];
  lm[HandFrame.thumbTip] = Landmark(tip.x - ratio * 0.13, tip.y, 0);
  return HandFrame(
    frameId: frameId,
    capturedAtMonotonicMs: frameId * 33,
    detected: true,
    handedness: 'RIGHT',
    landmarks: lm,
  );
}

/// 描画ジェスチャー（人差し指＋中指くっつき）のフレーム。両先端を [camTip] に
/// 一致させ、筆点（中間点）が camTip と厳密に一致するようにする（歪み補正の
/// 検証で座標がブレないため）。
HandFrame drawFrameAt(int frameId, Vec2 camTip) {
  final f = MockHand.at(
    frameId: frameId,
    tip: camTip,
    pinch: false,
    together: true,
  );
  final lm = [...f.landmarks];
  lm[HandFrame.middleTip] = Landmark(camTip.x, camTip.y, 0); // index tip と一致
  return HandFrame(
    frameId: frameId,
    capturedAtMonotonicMs: frameId * 33,
    detected: true,
    handedness: 'RIGHT',
    landmarks: lm,
  );
}

void main() {
  group('Homography.fromCorners（傾いた四隅）', () {
    test('台形の既知の手位置が期待スライド座標へ正写される', () {
      final fwd = slideToCam(tiltedQuad);
      final h = Homography.fromCorners(tiltedQuad)!;
      const samples = [
        Vec2(0.25, 0.5),
        Vec2(0.8, 0.2),
        Vec2(0.5, 0.9),
        Vec2(0.05, 0.05),
      ];
      for (final s in samples) {
        final cam = fwd.map(s); // 「その角度から見た」カメラ上の手位置
        final back = h.map(cam);
        expect(back.x, closeTo(s.x, 1e-6), reason: 'sample $s');
        expect(back.y, closeTo(s.y, 1e-6), reason: 'sample $s');
      }
    });

    test('四隅の入力順序に依存しない', () {
      final base = Homography.fromCorners(tiltedQuad)!;
      const perms = [
        [2, 0, 3, 1],
        [3, 2, 1, 0],
        [1, 3, 0, 2],
      ];
      final probe = slideToCam(tiltedQuad).map(const Vec2(0.3, 0.6));
      final want = base.map(probe);
      for (final p in perms) {
        final h = Homography.fromCorners([for (final i in p) tiltedQuad[i]])!;
        final got = h.map(probe);
        expect(got.x, closeTo(want.x, 1e-9), reason: 'perm $p');
        expect(got.y, closeTo(want.y, 1e-9), reason: 'perm $p');
      }
    });

    test('退化した四隅（一直線）は null', () {
      expect(
        Homography.fromCorners(const [
          Vec2(0.1, 0.1),
          Vec2(0.4, 0.4),
          Vec2(0.7, 0.7),
          Vec2(0.9, 0.9),
        ]),
        isNull,
      );
    });
  });

  group('ピンチ判定ヒステリシス', () {
    test('ON/OFFしきい値の間ではチャタリングしない', () {
      final rec = GestureRecognizer(); // on=0.40 / off=0.60
      HandPose at(int i, double r) => rec.recognize(frameWithPinchRatio(i, r))!;
      expect(at(0, 0.50).pinching, isFalse); // 中間: まだOFF
      expect(at(1, 0.35).pinching, isTrue); // on未満: ON
      expect(at(2, 0.50).pinching, isTrue); // 中間: ONを維持（ヒステリシス）
      expect(at(3, 0.58).pinching, isTrue); // off以下: まだON
      expect(at(4, 0.65).pinching, isFalse); // off超: OFF
      expect(at(5, 0.50).pinching, isFalse); // 中間: OFFを維持
    });

    test('reset でピンチ状態が初期化される', () {
      final rec = GestureRecognizer();
      expect(rec.recognize(frameWithPinchRatio(0, 0.35))!.pinching, isTrue);
      rec.reset();
      expect(rec.recognize(frameWithPinchRatio(1, 0.50))!.pinching, isFalse);
    });
  });

  group('傾いた四隅でのストローク生成（エンジン→モデル）', () {
    test('2本指くっつきの軌跡が1本の連続ストロークとして歪み補正されて残る', () {
      final engine = InteractionEngine();
      // 順不同で校正（順序不変性も同時に確認）
      expect(
        engine.calibrateFromCorners([
          tiltedQuad[2],
          tiltedQuad[0],
          tiltedQuad[3],
          tiltedQuad[1],
        ]),
        isTrue,
      );
      expect(engine.mode, EngineMode.tracking);

      final fwd = slideToCam(tiltedQuad);
      final model = OverlayModel();
      void feed(int i, Vec2 slide, bool drawing) {
        final cam = fwd.map(slide);
        final f =
            drawing
                ? drawFrameAt(i, cam)
                : MockHand.at(frameId: i, tip: cam, pinch: false);
        for (final e in engine.onFrame(f)) {
          model.apply(e);
        }
      }

      // 接近（描画なし・v=0.5固定）→ 水平線 u:0.15→0.85 → 離す
      for (var i = 0; i < 10; i++) {
        feed(i, Vec2(0.05 + 0.01 * i, 0.5), false);
      }
      for (var i = 0; i < 60; i++) {
        feed(10 + i, Vec2(0.15 + 0.70 * i / 59.0, 0.5), true);
      }
      feed(70, const Vec2(0.85, 0.5), false);

      expect(model.strokes.length, 1, reason: '描画1回=ストローク1本');
      final pts = model.strokes.single.points;
      expect(pts.length, greaterThan(10), reason: '連続した点列である');
      for (final p in pts) {
        expect(p.y, closeTo(0.5, 1e-3), reason: '歪み補正後は水平線に乗る');
      }
      for (var i = 1; i < pts.length; i++) {
        expect(
          pts[i].x,
          greaterThanOrEqualTo(pts[i - 1].x - 1e-9),
          reason: 'xが単調（線が逆戻りしない）',
        );
      }
      // 始点は平滑化の追従遅れぶんだけ手前に出る（One-Euroの仕様どおり）。
      expect(pts.first.x, inInclusiveRange(0.10, 0.20));
      expect(pts.last.x, greaterThan(0.75), reason: '平滑化の遅延を許容しつつ終点近くまで届く');
    });
  });

  group('slide_corners のWS経路（実サーバE2E）', () {
    test('hello→slide_corners→hand_frameで校正され、補正済み座標の描画イベントが出る', () async {
      final events = <InteractionEvent>[];
      final engine = InteractionEngine();
      final server = InputServer(
        engine: engine,
        port: 0, // 空きポート（ユーザーの起動中アプリ8765と衝突させない）
        onEvents: events.addAll,
        onStatus: (_) {},
      );
      await server.start();
      addTearDown(server.stop);

      final ws = await WebSocket.connect(
        'ws://localhost:${server.boundPort}/ws/v1/input',
      );
      addTearDown(ws.close);
      final ack = Completer<void>();
      ws.listen((data) {
        final j = jsonDecode(data as String) as Map<String, dynamic>;
        if (j['messageType'] == 'hello_ack' && !ack.isCompleted) {
          ack.complete();
        }
      });

      void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));
      send({
        'schemaVersion': 1,
        'messageType': 'hello',
        'deviceId': 'test-client',
      });
      await ack.future.timeout(const Duration(seconds: 5));

      send({
        'schemaVersion': 1,
        'messageType': 'slide_corners',
        'capturedAtMonotonicMs': 0,
        'corners': [
          [tiltedQuad[2].x, tiltedQuad[2].y],
          [tiltedQuad[0].x, tiltedQuad[0].y],
          [tiltedQuad[3].x, tiltedQuad[3].y],
          [tiltedQuad[1].x, tiltedQuad[1].y],
        ],
      });

      final fwd = slideToCam(tiltedQuad);
      for (var i = 0; i < 40; i++) {
        final slide = Vec2(0.2 + 0.5 * i / 39.0, 0.5);
        final cam = fwd.map(slide);
        // i>=5 で「2本指くっつき」＝描画。
        final f =
            i >= 5
                ? drawFrameAt(i, cam)
                : MockHand.at(frameId: i, tip: cam, pinch: false);
        send({
          'schemaVersion': 1,
          'messageType': 'hand_frame',
          'frameId': f.frameId,
          'capturedAtMonotonicMs': f.capturedAtMonotonicMs,
          'hand': {
            'detected': true,
            'handedness': 'RIGHT',
            'landmarks': [
              for (final l in f.landmarks) [l.x, l.y, l.z],
            ],
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      // 到着待ち（最新優先処理のため全フレームは処理されないが、描画イベントは出る）
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(engine.isCalibrated, isTrue);
      expect(engine.mode, EngineMode.tracking);
      final draws =
          events
              .where(
                (e) =>
                    e.kind == InteractionKind.drawDown ||
                    e.kind == InteractionKind.drawMove,
              )
              .toList();
      expect(draws, isNotEmpty, reason: '2本指くっつきで描画イベントが出る');
      for (final e in draws) {
        expect(e.screen.y, closeTo(0.5, 1e-3), reason: '歪み補正済みの座標');
        expect(e.screen.x, inInclusiveRange(0.15, 0.75));
      }
    });
  });
}
