import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/calibration_config.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/homography.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/net/input_server.dart';
import 'package:thehack_overlay/protocol/messages.dart';
import 'package:thehack_overlay/ui/calibration_flow.dart';

/// キャリブ画像のマーカー中心（画面正規化）。TL, TR, BR, BL = ID 10,11,12,13。
const ix = CalibrationConfig.targetMarkerInsetX; // 0.125
const iy = CalibrationConfig.targetMarkerInsetY; // 0.2222

List<Vec2> targetCenters() => Homography.insetRect(ix, iy);

Marker markerAt(int id, Vec2 c) => Marker(id, c, [
  Vec2(c.x - .02, c.y - .02),
  Vec2(c.x + .02, c.y - .02),
  Vec2(c.x + .02, c.y + .02),
  Vec2(c.x - .02, c.y + .02),
]);

/// ID 10..13 のマーカーを指定のカメラ座標に置いた calibration_markers。
CalibrationMarkers markersFrom(List<Vec2> centers) => CalibrationMarkers(0, [
  for (var i = 0; i < 4; i++)
    markerAt(Homography.cornerMarkerIds[i], centers[i]),
]);

void main() {
  group('ID対応付け＋マーカーインセット外挿', () {
    test('カメラ＝画面が一致する置き方なら恒等写像になる', () {
      final h =
          Homography.fromMarkers(
            markersFrom(targetCenters()).markers,
            insetX: ix,
            insetY: iy,
          )!;
      const samples = [
        Vec2(0, 0),
        Vec2(1, 1),
        Vec2(0.2, 0.3),
        Vec2(0.87, 0.05),
      ];
      for (final s in samples) {
        final m = h.map(s);
        expect(m.x, closeTo(s.x, 1e-6), reason: 'sample $s');
        expect(m.y, closeTo(s.y, 1e-6), reason: 'sample $s');
      }
    });

    test('マーカー中心は画面端でなく内側（インセット外挿で端まで届く）', () {
      // インセット補正なし（従来のfull-corner対応）だと、マーカー中心が
      // 画面四隅扱いになり内側の領域しか使えない。補正ありは全域が写る。
      final noInset =
          Homography.fromMarkers(markersFrom(targetCenters()).markers)!;
      final tl = noInset.map(const Vec2(ix, iy));
      expect(tl.x, closeTo(0, 1e-6)); // 補正なし: マーカー位置→(0,0)
      expect(tl.y, closeTo(0, 1e-6));

      final withInset =
          Homography.fromMarkers(
            markersFrom(targetCenters()).markers,
            insetX: ix,
            insetY: iy,
          )!;
      final same = withInset.map(const Vec2(ix, iy));
      expect(same.x, closeTo(ix, 1e-6)); // 補正あり: マーカー位置はそのまま
      expect(same.y, closeTo(iy, 1e-6));
    });

    test('スマホが180度回転して見ていてもIDの対応付けで正しく写る', () {
      // カメラが上下逆さま: 画面点 s はカメラ上では (1-x, 1-y) に見える。
      Vec2 rot(Vec2 p) => Vec2(1 - p.x, 1 - p.y);
      final centers = [for (final c in targetCenters()) rot(c)];
      final h =
          Homography.fromMarkers(
            markersFrom(centers).markers,
            insetX: ix,
            insetY: iy,
          )!;
      const samples = [Vec2(0.2, 0.3), Vec2(0.9, 0.8), Vec2(0.0, 1.0)];
      for (final s in samples) {
        final m = h.map(rot(s));
        expect(m.x, closeTo(s.x, 1e-6), reason: 'sample $s');
        expect(m.y, closeTo(s.y, 1e-6), reason: 'sample $s');
      }
    });

    test('斜めから見た場合もマーカーインセット外挿で画面全域が正写される', () {
      // 画面全域→カメラ台形の順方向ホモグラフィで「その角度から見た」座標を合成。
      final fwd =
          Homography.fromCorrespondences(
            const [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)],
            const [
              Vec2(0.18, 0.20),
              Vec2(0.84, 0.12),
              Vec2(0.95, 0.80),
              Vec2(0.08, 0.68),
            ],
          )!;
      final centers = [for (final c in targetCenters()) fwd.map(c)];
      final h =
          Homography.fromMarkers(
            markersFrom(centers).markers,
            insetX: ix,
            insetY: iy,
          )!;
      const samples = [Vec2(0.05, 0.05), Vec2(0.5, 0.5), Vec2(0.95, 0.9)];
      for (final s in samples) {
        final m = h.map(fwd.map(s));
        expect(m.x, closeTo(s.x, 1e-6), reason: 'sample $s');
        expect(m.y, closeTo(s.y, 1e-6), reason: 'sample $s');
      }
    });
  });

  group('slide_corners の四隅インセット補正', () {
    test('検知四隅が実画面より内側でも設定した内側率で端まで外挿される', () {
      final fwd =
          Homography.fromCorrespondences(
            const [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)],
            const [
              Vec2(0.18, 0.20),
              Vec2(0.84, 0.12),
              Vec2(0.95, 0.80),
              Vec2(0.08, 0.68),
            ],
          )!;
      // 検知点は画面端から5%内側に寄っている想定。
      final detected = [
        for (final c in Homography.insetRect(0.05, 0.05)) fwd.map(c),
      ];
      final h = Homography.fromCorners(detected, insetX: 0.05, insetY: 0.05)!;
      const samples = [Vec2(0, 0), Vec2(1, 1), Vec2(0.3, 0.7)];
      for (final s in samples) {
        final m = h.map(fwd.map(s));
        expect(m.x, closeTo(s.x, 1e-6), reason: 'sample $s');
        expect(m.y, closeTo(s.y, 1e-6), reason: 'sample $s');
      }
    });
  });

  group('安定判定と受付ソース設定', () {
    test('requiredStableMessages 回連続で受けるまで確定しない', () {
      final engine = InteractionEngine(
        config: CalibrationConfig(requiredStableMessages: 3),
      );
      expect(engine.calibrate(MockHand.markers()), isFalse);
      expect(engine.isCalibrated, isFalse);
      expect(engine.calibrate(MockHand.markers()), isFalse);
      expect(engine.calibrate(MockHand.markers()), isTrue);
      expect(engine.isCalibrated, isTrue);
      expect(engine.mode, EngineMode.tracking);
      expect(engine.calibrationCount, 1);
    });

    test('不正メッセージで連続カウントがリセットされる', () {
      final engine = InteractionEngine(
        config: CalibrationConfig(requiredStableMessages: 3),
      );
      engine.calibrate(MockHand.markers());
      engine.calibrate(MockHand.markers());
      // 3マーカーしかない不正データ → リセット
      final bad = CalibrationMarkers(
        0,
        MockHand.markers().markers.take(3).toList(),
      );
      expect(engine.calibrate(bad), isFalse);
      expect(engine.calibrate(MockHand.markers()), isFalse);
      expect(engine.calibrate(MockHand.markers()), isFalse);
      expect(engine.calibrate(MockHand.markers()), isTrue);
    });

    test('source=slideCornersOnly は calibration_markers を無視する', () {
      final engine = InteractionEngine(
        config: CalibrationConfig(source: CalibrationSource.slideCornersOnly),
      );
      expect(engine.calibrate(MockHand.markers()), isFalse);
      expect(engine.isCalibrated, isFalse);
      expect(
        engine.calibrateFromCorners(const [
          Vec2(0.1, 0.1),
          Vec2(0.9, 0.1),
          Vec2(0.9, 0.9),
          Vec2(0.1, 0.9),
        ]),
        isTrue,
      );
    });

    test('source=arucoOnly は slide_corners を無視する', () {
      final engine = InteractionEngine(
        config: CalibrationConfig(source: CalibrationSource.arucoOnly),
      );
      expect(
        engine.calibrateFromCorners(const [
          Vec2(0.1, 0.1),
          Vec2(0.9, 0.1),
          Vec2(0.9, 0.9),
          Vec2(0.1, 0.9),
        ]),
        isFalse,
      );
      expect(engine.isCalibrated, isFalse);
      expect(engine.calibrate(MockHand.markers()), isTrue);
    });

    test('既定設定（インセット0・安定1・両方）は従来挙動のまま', () {
      final engine = InteractionEngine();
      expect(engine.calibrate(MockHand.markers()), isTrue);
      expect(engine.mode, EngineMode.tracking);
    });
  });

  group('CalibrationFlowController（設置完了→画像表示→四隅受信→自動クローズ）', () {
    test('開始で showingTarget、位置合わせ成功エポックの増加で done', () {
      final flow = CalibrationFlowController();
      expect(flow.state, CalibrationFlowState.idle);

      flow.start(0);
      expect(flow.state, CalibrationFlowState.showingTarget);
      expect(flow.showingTarget, isTrue);

      flow.onEngineEpoch(0); // まだ成功していない → 表示継続
      expect(flow.state, CalibrationFlowState.showingTarget);

      flow.onEngineEpoch(1); // 四隅受信で成功 → 自動クローズ
      expect(flow.state, CalibrationFlowState.done);
    });

    test('再キャリブ: 既に成功済み(epoch>0)でも開始時点からの増加で判定する', () {
      final flow = CalibrationFlowController();
      flow.start(3);
      flow.onEngineEpoch(3);
      expect(flow.state, CalibrationFlowState.showingTarget);
      flow.onEngineEpoch(4);
      expect(flow.state, CalibrationFlowState.done);
    });

    test('cancel は表示中のみ idle へ戻す', () {
      final flow = CalibrationFlowController();
      flow.cancel();
      expect(flow.state, CalibrationFlowState.idle);
      flow.start(0);
      flow.cancel();
      expect(flow.state, CalibrationFlowState.idle);
      flow.start(0);
      flow.onEngineEpoch(1);
      flow.cancel(); // done は維持
      expect(flow.state, CalibrationFlowState.done);
    });
  });

  group('WS経由の一連フロー（実サーバE2E）', () {
    test('calibration_markers 受信で校正され、完了通知(set_mode tracking)が返る', () async {
      final engine = InteractionEngine(
        config: CalibrationConfig.forCalibrationTarget(),
      );
      final flow = CalibrationFlowController();
      final statuses = <ServerStatus>[];
      final server = InputServer(
        engine: engine,
        port: 0, // 空きポート（稼働中アプリの8765と衝突させない）
        onEvents: (_) {},
        onStatus: (st) {
          statuses.add(st);
          flow.onEngineEpoch(engine.calibrationCount);
        },
      );
      await server.start();
      addTearDown(server.stop);

      final ws = await WebSocket.connect(
        'ws://localhost:${server.boundPort}/ws/v1/input',
      );
      addTearDown(ws.close);
      final ack = Completer<void>();
      final trackingNotified = Completer<void>();
      ws.listen((data) {
        final j = jsonDecode(data as String) as Map<String, dynamic>;
        if (j['messageType'] == 'hello_ack' && !ack.isCompleted) {
          ack.complete();
        }
        if (j['messageType'] == 'control_message' &&
            j['command'] == 'set_mode' &&
            j['mode'] == 'tracking' &&
            !trackingNotified.isCompleted) {
          trackingNotified.complete();
        }
      });

      void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));
      send({
        'schemaVersion': 1,
        'messageType': 'hello',
        'deviceId': 'test-phone',
      });
      await ack.future.timeout(const Duration(seconds: 5));

      // 「スマホ設置完了」でキャリブ画像を表示した状態を再現。
      flow.start(engine.calibrationCount);
      expect(flow.showingTarget, isTrue);

      // スマホがキャリブ画像のマーカー4隅を検知して送ってくる。
      final centers = targetCenters();
      send({
        'schemaVersion': 1,
        'messageType': 'calibration_markers',
        'capturedAtMonotonicMs': 0,
        'markers': [
          for (var i = 0; i < 4; i++)
            {
              'id': Homography.cornerMarkerIds[i],
              'center': [centers[i].x, centers[i].y],
              'corners': [
                [centers[i].x - .02, centers[i].y - .02],
                [centers[i].x + .02, centers[i].y - .02],
                [centers[i].x + .02, centers[i].y + .02],
                [centers[i].x - .02, centers[i].y + .02],
              ],
            },
        ],
      });

      await trackingNotified.future.timeout(const Duration(seconds: 5));
      // 少し待って onStatus 経由の flow 更新を反映。
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.isCalibrated, isTrue);
      expect(
        flow.state,
        CalibrationFlowState.done,
        reason: '四隅受信でキャリブ画像が自動クローズされる',
      );
      expect(statuses.last.mode, EngineMode.tracking);
      expect(statuses.last.lastError, isNull);
    });

    test('acceptCalibrationMessages=falseでは正しいマーカーも無視し、true後だけ校正する', () async {
      final engine = InteractionEngine(
        config: CalibrationConfig.forCalibrationTarget(),
      );
      final server = InputServer(
        engine: engine,
        port: 0,
        acceptCalibrationMessages: false,
        onEvents: (_) {},
        onStatus: (_) {},
      );
      await server.start();
      addTearDown(server.stop);

      final ws = await WebSocket.connect(
        'ws://localhost:${server.boundPort}/ws/v1/input',
      );
      addTearDown(ws.close);
      final ack = Completer<void>();
      final trackingNotified = Completer<void>();
      ws.listen((data) {
        final json = jsonDecode(data as String) as Map<String, dynamic>;
        if (json['messageType'] == 'hello_ack' && !ack.isCompleted) {
          ack.complete();
        }
        if (json['messageType'] == 'control_message' &&
            json['command'] == 'set_mode' &&
            json['mode'] == 'tracking' &&
            !trackingNotified.isCompleted) {
          trackingNotified.complete();
        }
      });

      ws.add(
        jsonEncode({
          'schemaVersion': 1,
          'messageType': 'hello',
          'deviceId': 'gated-calibration-phone',
        }),
      );
      await ack.future.timeout(const Duration(seconds: 5));

      final centers = targetCenters();
      final markers = {
        'schemaVersion': 1,
        'messageType': 'calibration_markers',
        'capturedAtMonotonicMs': 0,
        'markers': [
          for (var i = 0; i < 4; i++)
            {
              'id': Homography.cornerMarkerIds[i],
              'center': [centers[i].x, centers[i].y],
              'corners': [
                [centers[i].x - .02, centers[i].y - .02],
                [centers[i].x + .02, centers[i].y - .02],
                [centers[i].x + .02, centers[i].y + .02],
                [centers[i].x - .02, centers[i].y + .02],
              ],
            },
        ],
      };

      ws.add(jsonEncode(markers));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(engine.isCalibrated, isFalse);
      expect(engine.calibrationCount, 0);
      expect(trackingNotified.isCompleted, isFalse);

      server.acceptCalibrationMessages = true;
      ws.add(jsonEncode(markers));
      await trackingNotified.future.timeout(const Duration(seconds: 5));
      expect(engine.isCalibrated, isTrue);
      expect(engine.calibrationCount, 1);
      expect(engine.mode, EngineMode.tracking);
    });

    test('source=slideCornersOnly 設定では calibration_markers が無視される', () async {
      final engine = InteractionEngine(
        config: CalibrationConfig(source: CalibrationSource.slideCornersOnly),
      );
      final server = InputServer(
        engine: engine,
        port: 0,
        onEvents: (_) {},
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
      ws.add(
        jsonEncode({
          'schemaVersion': 1,
          'messageType': 'hello',
          'deviceId': 'test-phone',
        }),
      );
      await ack.future.timeout(const Duration(seconds: 5));

      final centers = targetCenters();
      ws.add(
        jsonEncode({
          'schemaVersion': 1,
          'messageType': 'calibration_markers',
          'capturedAtMonotonicMs': 0,
          'markers': [
            for (var i = 0; i < 4; i++)
              {
                'id': Homography.cornerMarkerIds[i],
                'center': [centers[i].x, centers[i].y],
                'corners': const [],
              },
          ],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.isCalibrated, isFalse);

      // slide_corners なら受け付ける。
      ws.add(
        jsonEncode({
          'schemaVersion': 1,
          'messageType': 'slide_corners',
          'capturedAtMonotonicMs': 0,
          'corners': [
            [0.1, 0.1],
            [0.9, 0.1],
            [0.9, 0.9],
            [0.1, 0.9],
          ],
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.isCalibrated, isTrue);
    });
  });
}
