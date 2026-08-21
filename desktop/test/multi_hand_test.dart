import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';

import 'fixtures/two_hand_fixtures.dart';

/// MockHand のポインタ姿勢（人差し指のみ伸展）で1トラック分の JSON を作る。
/// 開いた手のfixtureはスクロール扱いになり単発フレームでイベントを出さないため、
/// 操作イベントを確実に検証する用途にはこの合成トラックを使う。
Map<String, dynamic> pointerTrack(int trackId, Vec2 tip, {bool pinch = false}) {
  final f = MockHand.at(frameId: 0, tip: tip, pinch: pinch);
  return {
    'trackId': trackId,
    'landmarks': [
      for (final l in f.landmarks) [l.x, l.y, l.z],
    ],
  };
}

/// 実Android送信と同様に全点をカメラ範囲へ収めつつ、ホモグラフィ後に
/// 人差し指が画面外になる境界テスト用トラック。
Map<String, dynamic> boundaryPointerTrack(int trackId, Vec2 tip) {
  final f = MockHand.at(frameId: 0, tip: tip, pinch: false);
  return {
    'trackId': trackId,
    'landmarks': [
      for (final l in f.landmarks)
        [l.x.clamp(0.0, 1.0), l.y.clamp(0.0, 1.0), l.z],
    ],
  };
}

Map<String, dynamic> multiHandFrame(
  int frameId,
  List<Map<String, dynamic>> hands, {
  String sessionId = 'session-01',
}) => {
  'schemaVersion': 1,
  'messageType': 'hand_frame',
  'sessionId': sessionId,
  'frameId': frameId,
  'capturedAtMonotonicMs': frameId * 33,
  'hands': hands,
};

/// 左手 7（左寄り）＋右手 12（右寄り）のポインタ2手フレーム。
InputFrame twoPointerHands(int frameId) =>
    InputFrame.parse(
      multiHandFrame(frameId, [
        pointerTrack(7, const Vec2(0.3, 0.5)),
        pointerTrack(12, const Vec2(0.7, 0.5)),
      ]),
    )!;

InputFrame onePointerHand(int frameId, {int trackId = 7, double x = 0.3}) =>
    InputFrame.parse(
      multiHandFrame(frameId, [pointerTrack(trackId, Vec2(x, 0.5))]),
    )!;

InputFrame noHands(int frameId) =>
    InputFrame.parse(multiHandFrame(frameId, const []))!;

void main() {
  group('InputFrame.parse 検証（不正は一部採用せずフレーム全体破棄）', () {
    test('2手フレームを trackId 昇順で解釈する', () {
      final f = InputFrame.parse(twoHandFrame())!;
      expect(f.tracks.map((t) => t.trackId), [7, 12]);
      expect(f.tracks[0].landmarks.length, 21);
      expect(f.tracks[1].landmarks.length, 21);
      expect(f.hasHands, isTrue);
      expect(f.fromCompatHand, isFalse);
    });

    test('hands があれば hand は無視する', () {
      // hand は LEFT(7) のコピーだが、hands が正本なので2トラックになる。
      final f = InputFrame.parse(twoHandFrame())!;
      expect(f.tracks.length, 2);
    });

    test('0手・1手の有効フレーム', () {
      expect(InputFrame.parse(zeroHandFrame())!.tracks, isEmpty);
      expect(InputFrame.parse(oneHandFrame())!.tracks.single.trackId, 7);
    });

    test('3手以上は破棄', () {
      final j = twoHandFrame();
      (j['hands'] as List).add(handPayload(20, hand7Landmarks));
      expect(InputFrame.parse(j), isNull);
    });

    test('trackId 重複は破棄', () {
      final j = twoHandFrame();
      j['hands'] = [
        handPayload(7, hand7Landmarks),
        handPayload(7, hand12Landmarks),
      ];
      expect(InputFrame.parse(j), isNull);
    });

    test('21点以外は破棄', () {
      final j = twoHandFrame();
      final short = [...hand7Landmarks]..removeLast();
      j['hands'] = [handPayload(7, short)];
      expect(InputFrame.parse(j), isNull);
    });

    test('NaN/Infinity を含む点は破棄', () {
      final j = twoHandFrame();
      final bad = [
        for (final p in hand7Landmarks) [...p],
      ];
      bad[5][0] = double.nan;
      j['hands'] = [handPayload(7, bad)];
      expect(InputFrame.parse(j), isNull);
    });

    test('x,y 範囲外は破棄（新 hands[] 経路）', () {
      final j = twoHandFrame();
      final bad = [
        for (final p in hand7Landmarks) [...p],
      ];
      bad[8][0] = 1.4; // x>1
      j['hands'] = [handPayload(7, bad)];
      expect(InputFrame.parse(j), isNull);
    });

    test('trackId が正整数でなければ破棄', () {
      final j = twoHandFrame();
      j['hands'] = [handPayload(0, hand7Landmarks)];
      expect(InputFrame.parse(j), isNull);
      j['hands'] = [handPayload(-3, hand7Landmarks)];
      expect(InputFrame.parse(j), isNull);
    });

    test('session不一致・認証後の欠落は破棄し、一致だけ受理', () {
      expect(
        InputFrame.parse(
          twoHandFrame(sessionId: 'session-99'),
          expectedSessionId: 'session-01',
        ),
        isNull,
      );
      expect(
        InputFrame.parse(twoHandFrame(), expectedSessionId: 'session-01'),
        isNotNull,
      );
      final missing = twoHandFrame()..remove('sessionId');
      expect(
        InputFrame.parse(missing, expectedSessionId: 'session-01'),
        isNull,
      );
    });

    test('frameIdと時刻が整数でなければ破棄', () {
      final fractionalFrame = twoHandFrame()..['frameId'] = 1.5;
      expect(InputFrame.parse(fractionalFrame), isNull);
      final fractionalTime = twoHandFrame()..['capturedAtMonotonicMs'] = 3.5;
      expect(InputFrame.parse(fractionalTime), isNull);
    });

    test('互換handが最小trackIdのコピーでなければ全体破棄', () {
      final wrongDetected = twoHandFrame();
      (wrongDetected['hand'] as Map<String, dynamic>)['detected'] = false;
      expect(InputFrame.parse(wrongDetected), isNull);

      final wrongLandmarks = twoHandFrame();
      final legacy = wrongLandmarks['hand'] as Map<String, dynamic>;
      final landmarks = [
        for (final p in legacy['landmarks'] as List) [...p as List],
      ];
      landmarks[8][0] = 0.99;
      legacy['landmarks'] = landmarks;
      expect(InputFrame.parse(wrongLandmarks), isNull);
    });

    test('schemaVersion 不一致は破棄', () {
      final j = twoHandFrame();
      j['schemaVersion'] = 2;
      expect(InputFrame.parse(j), isNull);
    });

    test('後方互換: hands なし・hand のみを単一トラックとして扱う', () {
      final j = {
        'schemaVersion': 1,
        'messageType': 'hand_frame',
        'frameId': 5,
        'capturedAtMonotonicMs': 100,
        'hand': {'detected': true, 'landmarks': hand7Landmarks},
      };
      final f = InputFrame.parse(j)!;
      expect(f.fromCompatHand, isTrue);
      expect(f.tracks.single.trackId, InputFrame.compatTrackId);
    });

    test('後方互換: hand.detected=false は0手フレーム', () {
      final j = {
        'schemaVersion': 1,
        'messageType': 'hand_frame',
        'frameId': 6,
        'hand': {'detected': false},
      };
      expect(InputFrame.parse(j)!.tracks, isEmpty);
    });
  });

  group('MultiHandEngine 2トラック分離', () {
    MultiHandEngine calibrated() {
      final e = MultiHandEngine();
      expect(e.calibrate(MockHand.markers()), isTrue);
      expect(e.isCalibrated, isTrue);
      return e;
    }

    test('2手を独立トラックとして処理し、両方のカーソルが別位置に出る', () {
      final e = calibrated();
      final out = e.onInputFrame(twoPointerHands(1))!;
      expect(out.keys.toSet(), {7, 12});
      expect(e.activeTrackCount, 2);
      // 左手 7 は左寄り、右手 12 は右寄り＝独立した画面座標。
      final p7 = out[7]!.last.screen;
      final p12 = out[12]!.last.screen;
      expect(p7.x, lessThan(p12.x));
    });

    test('1手フレームでは受信した1トラック分だけ状態を保持する', () {
      final e = calibrated();

      final first = e.onInputFrame(onePointerHand(1, trackId: 7))!;
      expect(first.keys, [7]);
      expect(e.activeTrackCount, 1);
      expect(e.activeTrackIds, [7]);

      e.onInputFrame(onePointerHand(2, trackId: 7));
      expect(e.activeTrackCount, 1, reason: '未受信の2手目用エンジンは事前生成しない');
    });

    test('片手が消えたら、その trackId だけ即時解除し他方は継続', () {
      final e = calibrated();
      e.onInputFrame(twoPointerHands(1));
      expect(e.activeTrackCount, 2);

      // 次フレームは hands=[7] のみ → 12 を解除、7 は継続。
      final out = e.onInputFrame(onePointerHand(2, trackId: 7))!;
      expect(out.containsKey(12), isTrue, reason: '12 の解除イベントが出る');
      expect(out[12]!.any((ev) => ev.kind == InteractionKind.release), isTrue);
      expect(out.containsKey(7), isTrue, reason: '7 は継続');
      expect(e.activeTrackCount, 1);
      expect(e.activeTrackIds, [7]);
    });

    test('hands=[] で全解除', () {
      final e = calibrated();
      e.onInputFrame(twoPointerHands(1));
      final out = e.onInputFrame(noHands(2))!;
      expect(out.keys.toSet(), {7, 12});
      for (final evs in out.values) {
        expect(evs.any((ev) => ev.kind == InteractionKind.release), isTrue);
      }
      expect(e.activeTrackCount, 0);
    });

    test('WS切断相当 releaseAll は全 trackId を即時解除', () {
      final e = calibrated();
      e.onInputFrame(twoPointerHands(1));
      final released = e.releaseAll();
      expect(released.keys.toSet(), {7, 12});
      for (final evs in released.values) {
        expect(evs.any((ev) => ev.kind == InteractionKind.release), isTrue);
      }
      expect(e.activeTrackCount, 0);
    });

    test('片手のドラッグ状態は他方の消失で解除されない（独立性）', () {
      final e = calibrated();
      // 7 をピンチ（押下）、12 はポインタ。
      e.onInputFrame(
        InputFrame.parse(
          multiHandFrame(1, [
            pointerTrack(7, const Vec2(0.3, 0.5), pinch: true),
            pointerTrack(12, const Vec2(0.7, 0.5)),
          ]),
        )!,
      );
      // 12 が消える。7 は押下継続（pressUp が出ない）。
      final out =
          e.onInputFrame(
            InputFrame.parse(
              multiHandFrame(2, [
                pointerTrack(7, const Vec2(0.32, 0.5), pinch: true),
              ]),
            )!,
          )!;
      expect(out[12]!.any((ev) => ev.kind == InteractionKind.release), isTrue);
      expect(out[7]!.any((ev) => ev.kind == InteractionKind.pressUp), isFalse);
      expect(out[7]!.any((ev) => ev.kind == InteractionKind.pressMove), isTrue);
    });

    test('単調増加でない frameId はフレーム全体破棄（null）', () {
      final e = calibrated();
      expect(e.onInputFrame(twoPointerHands(10)), isNotNull);
      expect(e.onInputFrame(twoPointerHands(10)), isNull); // 重複 → 破棄
      expect(e.onInputFrame(twoPointerHands(5)), isNull); // 巻き戻り → 破棄
      expect(e.onInputFrame(twoPointerHands(11)), isNotNull); // 前進 → 受理
    });

    test('PCは trackId を付け直さない（受信IDをそのまま使う）', () {
      final e = calibrated();
      final out = e.onInputFrame(twoPointerHands(1))!;
      expect(out.keys.toSet(), {7, 12});
      final out2 = e.onInputFrame(onePointerHand(2, trackId: 12, x: 0.7))!;
      // 7 は消えて解除、12 はそのまま継続（新IDを振り直さない）。
      expect(out2.containsKey(12), isTrue);
      expect(e.activeTrackIds, [12]);
    });

    test('感度/平滑化は全トラックへ伝播し、以後も処理できる', () {
      final e = calibrated();
      e.onInputFrame(twoPointerHands(1));
      e.recognitionSensitivity = 0.8;
      e.smoothingEnabled = false;
      expect(e.onInputFrame(twoPointerHands(2)), isNotNull);
    });

    test('後方互換 hand フレームも単一トラックとして操作を生む', () {
      final e = calibrated();
      final base = MockHand.at(
        frameId: 0,
        tip: const Vec2(0.5, 0.5),
        pinch: false,
      );
      final j = {
        'schemaVersion': 1,
        'messageType': 'hand_frame',
        'frameId': 1,
        'capturedAtMonotonicMs': 33,
        'hand': {
          'detected': true,
          'landmarks': [
            for (final l in base.landmarks) [l.x, l.y, l.z],
          ],
        },
      };
      final out = e.onInputFrame(InputFrame.parse(j)!)!;
      expect(out.keys, [InputFrame.compatTrackId]);
      expect(
        out[InputFrame.compatTrackId]!.any(
          (ev) => ev.kind == InteractionKind.pointerMove,
        ),
        isTrue,
      );
    });

    test('骨格用surface変換は画面外座標を端へ丸めない', () {
      final e = calibrated();
      final outside = e.mapToSurface(const Vec2(0.05, 0.5));
      expect(outside.x, lessThan(0));
      expect(outside.y, closeTo(0.5, 1e-6));
    });

    test('OS主トラックは2フレーム安定後に選び、画面外でも交代しない', () {
      final e = calibrated();
      final first = e.onInputFrame(twoPointerHands(1))!;
      expect(e.primaryTrackId, isNull);
      expect(e.primaryTrackIdOf(first), isNull);

      final second = e.onInputFrame(twoPointerHands(2))!;
      expect(e.primaryTrackId, 7);
      expect(e.primaryTrackIdOf(second), 7);

      final exit =
          e.onInputFrame(
            InputFrame.parse(
              multiHandFrame(3, [
                boundaryPointerTrack(7, const Vec2(0.05, 0.5)),
                pointerTrack(12, const Vec2(0.7, 0.5)),
              ]),
            )!,
          )!;
      expect(
        exit[7]!.any((event) => event.kind == InteractionKind.pointerExit),
        isTrue,
      );
      expect(e.primaryTrackId, 7);
      expect(e.primaryTrackIdOf(exit), 7);

      final stillOutside =
          e.onInputFrame(
            InputFrame.parse(
              multiHandFrame(4, [
                boundaryPointerTrack(7, const Vec2(0.05, 0.5)),
                pointerTrack(12, const Vec2(0.72, 0.5)),
              ]),
            )!,
          )!;
      expect(stillOutside.containsKey(7), isFalse);
      expect(e.primaryTrackId, 7);
      expect(e.primaryTrackIdOf(stillOutside), isNull);
    });

    test('最初からピンチ中でも主トラックを選びpressDownを補完する', () {
      final e = calibrated();
      InputFrame pinching(int frameId) => InputFrame.parse(
        multiHandFrame(frameId, [
          pointerTrack(7, const Vec2(0.4, 0.5), pinch: true),
        ]),
      )!;

      final first = e.onInputFrame(pinching(1))!;
      expect(e.primaryTrackId, isNull);
      expect(e.primaryEventsOf(first), isNull);

      final second = e.onInputFrame(pinching(2))!;
      expect(e.primaryTrackId, 7);
      expect(
        e.primaryEventsOf(second)!.map((event) => event.kind),
        [InteractionKind.pressDown, InteractionKind.pressMove],
      );
    });

    test('主トラック消失フレームは旧解除だけを選び、次候補を後で引き継ぐ', () {
      final e = calibrated();
      e.onInputFrame(twoPointerHands(1));
      e.onInputFrame(twoPointerHands(2));
      expect(e.primaryTrackId, 7);

      final vanished = e.onInputFrame(onePointerHand(3, trackId: 12, x: 0.7))!;
      expect(
        vanished[7]!.any((event) => event.kind == InteractionKind.release),
        isTrue,
      );
      expect(e.primaryTrackIdOf(vanished), 7);
      expect(e.primaryTrackId, isNull);

      final candidate1 =
          e.onInputFrame(onePointerHand(4, trackId: 12, x: 0.7))!;
      expect(e.primaryTrackIdOf(candidate1), isNull);
      expect(e.primaryTrackId, isNull);

      final candidate2 =
          e.onInputFrame(onePointerHand(5, trackId: 12, x: 0.7))!;
      expect(e.primaryTrackId, 12);
      expect(e.primaryTrackIdOf(candidate2), 12);
    });
  });
}
