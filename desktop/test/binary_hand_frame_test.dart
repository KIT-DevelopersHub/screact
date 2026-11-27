import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/protocol/binary_hand_frame.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';
import 'package:thehack_overlay/protocol/messages.dart';

import 'fixtures/two_hand_fixtures.dart';

typedef C = BinaryHandFrameCodec;

List<Landmark> _lm(List<List<double>> raw) => [
  for (final p in raw) Landmark(p[0], p[1], p[2]),
];

BinaryHand _hand(
  int id,
  List<List<double>> raw, {
  String? handedness = 'LEFT',
  double? score = 0.96,
}) => BinaryHand(
  trackId: id,
  handedness: handedness,
  handednessScore: score,
  landmarks: _lm(raw),
);

BinaryHandFrame _twoHands({bool includeZ = true, bool withSource = true}) =>
    BinaryHandFrame(
      frameId: 1842,
      capturedAtMonotonicMs: 19384521,
      includeZ: includeZ,
      source:
          withSource
              ? const BinaryHandFrameSource(
                width: 960,
                height: 540,
                rotationDegrees: 90,
                rotationCorrected: true,
                mirrorCorrected: true,
                cameraFacing: 'front',
              )
              : null,
      hands: [
        _hand(7, hand7Landmarks),
        _hand(12, hand12Landmarks, handedness: 'RIGHT', score: null),
      ],
    );

/// [bytes] の [offset] の 1 バイトを書き換えた複製。
Uint8List _patch(Uint8List bytes, int offset, int value) =>
    Uint8List.fromList(bytes)..[offset] = value;

void _expectLandmarksClose(
  List<Landmark> actual,
  List<Landmark> expected, {
  required bool includeZ,
}) {
  expect(actual.length, expected.length);
  for (var i = 0; i < actual.length; i++) {
    expect(
      (actual[i].x - expected[i].x).abs(),
      lessThanOrEqualTo(C.maxXyError),
    );
    expect(
      (actual[i].y - expected[i].y).abs(),
      lessThanOrEqualTo(C.maxXyError),
    );
    if (includeZ) {
      expect(
        (actual[i].z - expected[i].z).abs(),
        lessThanOrEqualTo(C.maxZError),
      );
    } else {
      expect(actual[i].z, 0);
    }
  }
}

void main() {
  group('往復（エンコード → デコード）', () {
    test('2 手・z あり・source ありで全項目が戻る', () {
      final src = _twoHands();
      final bytes = C.encode(src);
      expect(
        bytes.length,
        C.frameSize(handCount: 2, includeZ: true, includeSource: true),
      );
      final out = C.decode(bytes);
      expect(out.frameId, 1842);
      expect(out.capturedAtMonotonicMs, 19384521);
      expect(out.includeZ, isTrue);
      expect(out.source!.width, 960);
      expect(out.source!.height, 540);
      expect(out.source!.rotationDegrees, 90);
      expect(out.source!.rotationCorrected, isTrue);
      expect(out.source!.mirrorCorrected, isTrue);
      expect(out.source!.cameraFacing, 'front');
      expect(out.hands.map((h) => h.trackId), [7, 12]);
      expect(out.hands[0].handedness, 'LEFT');
      expect(out.hands[1].handedness, 'RIGHT');
      expect(
        (out.hands[0].handednessScore! - 0.96).abs(),
        lessThanOrEqualTo(C.maxScoreError),
      );
      expect(out.hands[1].handednessScore, isNull);
      for (var i = 0; i < 2; i++) {
        _expectLandmarksClose(
          out.hands[i].landmarks,
          src.hands[i].landmarks,
          includeZ: true,
        );
      }
    });

    test('z なし・source なしでは z が 0 になる', () {
      final src = _twoHands(includeZ: false, withSource: false);
      final out = C.decode(C.encode(src));
      expect(out.source, isNull);
      expect(out.includeZ, isFalse);
      _expectLandmarksClose(
        out.hands[0].landmarks,
        src.hands[0].landmarks,
        includeZ: false,
      );
    });

    test('0 手は未検出の通知としてヘッダだけになる', () {
      const src = BinaryHandFrame(
        frameId: 5,
        capturedAtMonotonicMs: 100,
        hands: [],
      );
      final bytes = C.encode(src);
      expect(bytes.length, C.headerSize);
      final out = C.decode(bytes);
      expect(out.hands, isEmpty);
      final f = out.toInputFrame(sessionId: 's');
      expect(f.hasHands, isFalse);
      expect(f.sessionId, 's');
    });

    test('frameId と時刻は u32 の端まで運べる', () {
      const src = BinaryHandFrame(
        frameId: 0xFFFFFFFF,
        capturedAtMonotonicMs: 0xFFFFFFFF,
        hands: [],
      );
      final out = C.decode(C.encode(src));
      expect(out.frameId, 0xFFFFFFFF);
      expect(out.capturedAtMonotonicMs, 0xFFFFFFFF);
    });
  });

  group('量子化の誤差', () {
    test('乱数の座標で、x/y/z/score の誤差が仕様の上限に収まる', () {
      final rnd = math.Random(20261128);
      var maxXy = 0.0, maxZ = 0.0, maxScore = 0.0;
      for (var n = 0; n < 500; n++) {
        final pts = [
          for (var k = 0; k < 21; k++)
            Landmark(
              rnd.nextDouble(),
              rnd.nextDouble(),
              rnd.nextDouble() * 2 - 1,
            ),
        ];
        // 端の値も混ぜる。
        if (n == 0) {
          pts[0] = const Landmark(0, 0, -1);
          pts[1] = const Landmark(1, 1, 1);
        }
        final score = rnd.nextDouble();
        final src = BinaryHandFrame(
          frameId: n,
          capturedAtMonotonicMs: n,
          hands: [
            BinaryHand(trackId: 1, landmarks: pts, handednessScore: score),
          ],
        );
        final out = C.decode(C.encode(src)).hands.single;
        for (var k = 0; k < 21; k++) {
          maxXy = math.max(maxXy, (out.landmarks[k].x - pts[k].x).abs());
          maxXy = math.max(maxXy, (out.landmarks[k].y - pts[k].y).abs());
          maxZ = math.max(maxZ, (out.landmarks[k].z - pts[k].z).abs());
        }
        maxScore = math.max(maxScore, (out.handednessScore! - score).abs());
      }
      expect(maxXy, lessThanOrEqualTo(C.maxXyError));
      expect(maxZ, lessThanOrEqualTo(C.maxZError));
      expect(maxScore, lessThanOrEqualTo(C.maxScoreError));
      // 上限の値そのもの（仕様の記載と一致させる）。
      expect(C.maxXyError, closeTo(7.63e-6, 1e-8));
      expect(C.maxZError, closeTo(1.53e-5, 1e-7));
      // 4K 画面幅に写したときの誤差は 0.05 px 未満。
      expect(C.maxXyError * 3840, lessThan(0.05));
    });

    test('z の範囲外は ±zRange に飽和する', () {
      expect(C.quantizeZ(5), C.zScale);
      expect(C.quantizeZ(-5), -C.zScale);
      final src = BinaryHandFrame(
        frameId: 1,
        capturedAtMonotonicMs: 1,
        hands: [
          BinaryHand(
            trackId: 1,
            landmarks: List.filled(21, const Landmark(0.5, 0.5, -3)),
          ),
        ],
      );
      final out = C.decode(C.encode(src)).hands.single;
      expect(out.landmarks.first.z, -C.zRange);
    });
  });

  group('JSON 経路の InputFrame と同じ結果になる', () {
    for (final (name, json) in [
      ('2 手', twoHandFrame()),
      ('1 手', oneHandFrame()),
      ('0 手', zeroHandFrame()),
    ]) {
      test(name, () {
        final fromJson = InputFrame.parse(json)!;
        final bytes = C.encode(BinaryHandFrame.fromInputFrame(fromJson));
        final fromBin = C.decodeInputFrame(bytes, sessionId: 'session-01')!;
        expect(fromBin.schemaVersion, fromJson.schemaVersion);
        expect(fromBin.sessionId, fromJson.sessionId);
        expect(fromBin.frameId, fromJson.frameId);
        expect(fromBin.capturedAtMonotonicMs, fromJson.capturedAtMonotonicMs);
        expect(fromBin.fromCompatHand, isFalse);
        expect(fromBin.tracks.length, fromJson.tracks.length);
        for (var i = 0; i < fromBin.tracks.length; i++) {
          final a = fromBin.tracks[i];
          final b = fromJson.tracks[i];
          expect(a.trackId, b.trackId);
          expect(a.handedness, b.handedness);
          _expectLandmarksClose(a.landmarks, b.landmarks, includeZ: true);
        }
      });
    }
  });

  group('デコーダは不正なバイト列を拒否する', () {
    final good = C.encode(_twoHands());

    void rejects(Uint8List bytes, String reason) {
      expect(() => C.decode(bytes), throwsFormatException, reason: reason);
      expect(C.tryDecode(bytes), isNull, reason: reason);
      expect(C.decodeInputFrame(bytes), isNull, reason: reason);
    }

    test('長さ', () {
      rejects(Uint8List(0), '空');
      rejects(Uint8List.sublistView(good, 0, C.headerSize - 1), 'ヘッダ未満');
      rejects(Uint8List.sublistView(good, 0, good.length - 1), '1 B 足りない');
      rejects(Uint8List.fromList([...good, 0]), '1 B 余る');
      // 手の数を 1 に書き換えると、2 手分の長さと合わない。
      rejects(_patch(good, 3, 1), '手の数と長さの不一致');
    });

    test('ヘッダの値', () {
      rejects(_patch(good, 0, 0x7B), 'magic（JSON の {）');
      rejects(_patch(good, 1, 2), '未対応の版');
      rejects(_patch(good, 2, good[2] | 0x80), '予約ビット');
      final three = Uint8List.fromList([
        ...good,
        ...Uint8List(C.handSize(includeZ: true)),
      ]);
      rejects(_patch(three, 3, 3), '3 手');
    });

    test('source の範囲外', () {
      rejects(_patch(good, C.headerSize + 4, 4), 'rotation 4（360 度）');
      rejects(_patch(good, C.headerSize + 5, 0x10), 'source の予約ビット');
      rejects(_patch(good, C.headerSize + 5, 0x0C), 'cameraFacing 3');
    });

    test('手の値の範囲外と trackId の重複', () {
      final hand0 = C.headerSize + C.sourceSize;
      final hand1 = hand0 + C.handSize(includeZ: true);
      // trackId = 0
      rejects(_patch(_patch(good, hand0, 0), hand0 + 1, 0), 'trackId 0');
      // 2 手目の trackId を 1 手目と同じ 7 にする。
      rejects(_patch(_patch(good, hand1, 7), hand1 + 1, 0), 'trackId 重複');
      // 2 手目の trackId を 3（1 手目より小さい）にする。
      rejects(_patch(_patch(good, hand1, 3), hand1 + 1, 0), 'trackId 降順');
      rejects(_patch(good, hand0 + 2, 3), 'handedness 3');
    });
  });

  test('score の 255 は省略、254 は 1.0', () {
    final good = C.encode(_twoHands());
    final hand0 = C.headerSize + C.sourceSize;
    final out = C.decode(_patch(good, hand0 + 3, 0xFF));
    expect(out.hands.first.handednessScore, isNull);
    expect(
      C.decode(_patch(good, hand0 + 3, 254)).hands.first.handednessScore,
      1,
    );
  });

  test('z の -32768 は範囲外として拒否する', () {
    final good = C.encode(_twoHands());
    final z0 = C.headerSize + C.sourceSize + C.handFixedSize + C.handXySize;
    final bad = _patch(_patch(good, z0, 0x00), z0 + 1, 0x80);
    expect(() => C.decode(bad), throwsFormatException);
  });

  group('エンコーダは仕様で表せない値を拒否する', () {
    BinaryHandFrame withHand(BinaryHand h) =>
        BinaryHandFrame(frameId: 1, capturedAtMonotonicMs: 1, hands: [h]);
    final ok = _lm(hand7Landmarks);

    test('座標・trackId・score・handedness', () {
      final outX = [...ok]..[0] = const Landmark(1.01, 0.5, 0);
      final nanY = [...ok]..[0] = const Landmark(0.5, double.nan, 0);
      final infZ = [...ok]..[0] = const Landmark(0.5, 0.5, double.infinity);
      expect(
        () => C.encode(withHand(BinaryHand(trackId: 1, landmarks: outX))),
        throwsRangeError,
      );
      expect(
        () => C.encode(withHand(BinaryHand(trackId: 1, landmarks: nanY))),
        throwsRangeError,
      );
      expect(
        () => C.encode(withHand(BinaryHand(trackId: 1, landmarks: infZ))),
        throwsArgumentError,
      );
      expect(
        () => C.encode(withHand(BinaryHand(trackId: 0, landmarks: ok))),
        throwsRangeError,
      );
      expect(
        () => C.encode(withHand(BinaryHand(trackId: 0x10000, landmarks: ok))),
        throwsRangeError,
      );
      expect(
        () => C.encode(
          withHand(BinaryHand(trackId: 1, landmarks: ok, handednessScore: 1.5)),
        ),
        throwsRangeError,
      );
      expect(
        () => C.encode(
          withHand(BinaryHand(trackId: 1, landmarks: ok, handedness: 'Left')),
        ),
        throwsArgumentError,
      );
      expect(
        () => C.encode(
          withHand(BinaryHand(trackId: 1, landmarks: ok.sublist(0, 20))),
        ),
        throwsArgumentError,
      );
    });

    test('手の数・並び・フレームの値', () {
      final h = BinaryHand(trackId: 3, landmarks: ok);
      expect(
        () => C.encode(
          BinaryHandFrame(
            frameId: 1,
            capturedAtMonotonicMs: 1,
            hands: [h, BinaryHand(trackId: 3, landmarks: ok)],
          ),
        ),
        throwsArgumentError,
        reason: 'trackId 重複',
      );
      expect(
        () => C.encode(
          BinaryHandFrame(
            frameId: 1,
            capturedAtMonotonicMs: 1,
            hands: [h, BinaryHand(trackId: 2, landmarks: ok)],
          ),
        ),
        throwsArgumentError,
        reason: 'trackId 降順',
      );
      expect(
        () => C.encode(
          BinaryHandFrame(
            frameId: 1,
            capturedAtMonotonicMs: 1,
            hands: [
              for (var i = 1; i <= 3; i++)
                BinaryHand(trackId: i, landmarks: ok),
            ],
          ),
        ),
        throwsArgumentError,
        reason: '3 手',
      );
      expect(
        () => C.encode(
          const BinaryHandFrame(
            frameId: -1,
            capturedAtMonotonicMs: 1,
            hands: [],
          ),
        ),
        throwsRangeError,
      );
      expect(
        () => C.encode(
          const BinaryHandFrame(
            frameId: 1,
            capturedAtMonotonicMs: 0x100000000,
            hands: [],
          ),
        ),
        throwsRangeError,
      );
      expect(
        () => C.encode(
          const BinaryHandFrame(
            frameId: 1,
            capturedAtMonotonicMs: 1,
            hands: [],
            source: BinaryHandFrameSource(
              width: 1,
              height: 1,
              rotationDegrees: 45,
            ),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('サイズ（JSON 比）', () {
    // Android の実送信に近い JSON を作る。座標は float の toString に近い 7 桁。
    Map<String, dynamic> realisticJson(int handCount) {
      final rnd = math.Random(42);
      double f7(double v) => double.parse(v.toStringAsPrecision(7));
      List<List<double>> pts() => [
        for (var k = 0; k < 21; k++)
          [
            f7(rnd.nextDouble()),
            f7(rnd.nextDouble()),
            f7(-rnd.nextDouble() * 0.1),
          ],
      ];
      final hands = [
        for (var i = 0; i < handCount; i++)
          {
            'trackId': 7 + i,
            'handedness': i == 0 ? 'LEFT' : 'RIGHT',
            'handednessScore': f7(0.9 + rnd.nextDouble() * 0.1),
            'coordinateSpace': 'normalized_camera',
            'landmarkFormat': 'mediapipe_hand_21',
            'landmarks': pts(),
          },
      ];
      return {
        'schemaVersion': 1,
        'messageType': 'hand_frame',
        'sessionId': 'session-fc30f9a1',
        'frameId': 1842,
        'capturedAtMonotonicMs': 19384521,
        'source': {
          'width': 960,
          'height': 540,
          'rotationDegrees': 0,
          'rotationCorrected': true,
          'mirrorCorrected': true,
          'cameraFacing': 'back',
        },
        'hands': hands,
        'hand':
            hands.isEmpty
                ? {'detected': false}
                : {
                  'detected': true,
                  'handedness': hands.first['handedness'],
                  'handednessScore': hands.first['handednessScore'],
                  'coordinateSpace': 'normalized_camera',
                  'landmarkFormat': 'mediapipe_hand_21',
                  'landmarks': hands.first['landmarks'],
                },
      };
    }

    test('バイト数が仕様の表どおりで、JSON より十分小さい', () {
      // 仕様（docs/system/binary-hand-frame-draft.md）の表と同じ値。
      expect(C.handSize(includeZ: false), 88);
      expect(C.handSize(includeZ: true), 130);
      final table = <(int, bool, bool), int>{
        (0, false, false): 12,
        (0, true, true): 18,
        (1, false, false): 100,
        (1, true, false): 142,
        (1, true, true): 148,
        (2, false, false): 188,
        (2, false, true): 194,
        (2, true, false): 272,
        (2, true, true): 278,
      };
      table.forEach((k, v) {
        final (n, z, s) = k;
        expect(
          C.frameSize(handCount: n, includeZ: z, includeSource: s),
          v,
          reason: '$k',
        );
      });

      final lines = <String>[];
      for (final n in [0, 1, 2]) {
        final json = realisticJson(n);
        final jsonBytes = utf8.encode(jsonEncode(json)).length;
        final frame = InputFrame.parse(json)!;
        final bin =
            C
                .encode(
                  BinaryHandFrame.fromInputFrame(
                    frame,
                    source: const BinaryHandFrameSource(
                      width: 960,
                      height: 540,
                      rotationCorrected: true,
                      mirrorCorrected: true,
                      cameraFacing: 'back',
                    ),
                  ),
                )
                .length;
        lines.add(
          '$n 手: JSON $jsonBytes B / バイナリ $bin B '
          '(${(bin / jsonBytes * 100).toStringAsFixed(1)}%)',
        );
        expect(bin, lessThan(jsonBytes * 0.2), reason: '$n 手');
      }
      // ignore: avoid_print
      print(lines.join('\n'));
    });
  });
}
