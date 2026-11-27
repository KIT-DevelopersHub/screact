import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';

/// 誤認識による微小ストローク（点のカス）の確定時破棄（Issue #5）を検証する。
/// 閾値は暫定値のため、実機での見え方は別途ハードで要確認。
void main() {
  late int now;
  late OverlayModel model;

  // 30fps 送信相当の1フレーム。
  const frameMs = 33;

  void at(int trackId, InteractionKind kind, Vec2 p) =>
      model.applyTrack(trackId, InteractionEvent(kind, p));

  /// [points] を1フレームずつ描く（先頭が drawDown、以降 drawMove）。終了はしない。
  void drawFrames(int trackId, List<Vec2> points) {
    for (var i = 0; i < points.length; i++) {
      if (i > 0) now += frameMs;
      at(
        trackId,
        i == 0 ? InteractionKind.drawDown : InteractionKind.drawMove,
        points[i],
      );
    }
  }

  List<Vec2> line(double x0, double x1, int n, {double y = 0.5}) => [
    for (var i = 0; i < n; i++) Vec2(x0 + (x1 - x0) * i / (n - 1), y),
  ];

  setUp(() {
    now = 1000;
    model = OverlayModel(nowMs: () => now);
  });

  group('誤認識は確定後に残らない', () {
    test('一瞬の点は描画中は表示され、drawUp で破棄される', () {
      drawFrames(0, const [Vec2(0.5, 0.5)]);
      expect(model.strokes, hasLength(1), reason: '描画中は即時表示する');
      now += frameMs;
      at(0, InteractionKind.drawUp, const Vec2(0.5, 0.5));
      expect(model.strokes, isEmpty);
    });

    test('数フレームの極短線は drawUp で破棄される', () {
      drawFrames(0, line(0.5, 0.506, 4));
      expect(model.strokes, hasLength(1));
      now += frameMs;
      at(0, InteractionKind.drawUp, const Vec2(0.506, 0.5));
      expect(model.strokes, isEmpty);
    });

    test('drawUp なしで次の drawDown が来ても、前の微小ストロークは破棄される', () {
      drawFrames(0, const [Vec2(0.2, 0.2)]);
      now += frameMs;
      drawFrames(0, line(0.3, 0.6, 12));
      expect(model.strokes, hasLength(1));
      expect(
        model.strokes.single.points.first.distanceTo(const Vec2(0.3, 0.5)),
        lessThan(1e-9),
      );
    });
  });

  group('正当な描画は消えない', () {
    test('通常の線は残り、末尾トリムも従来どおり効く', () {
      final pts = line(0.1, 0.6, 20);
      drawFrames(0, pts);
      at(0, InteractionKind.drawUp, pts.last);
      expect(model.strokes, hasLength(1));
      expect(
        model.strokes.single.points,
        hasLength(pts.length - model.penReleaseTrimPoints),
      );
    });

    test('素早い短線は末尾トリムで1点になっても残る（判定はトリム前）', () {
      // 4点・約100ms・軌跡長0.03。トリム3点で1点化される。
      drawFrames(0, line(0.5, 0.53, 4));
      at(0, InteractionKind.drawUp, const Vec2(0.53, 0.5));
      expect(model.strokes, hasLength(1));
      expect(model.strokes.single.points, hasLength(1));
    });

    test('長押しした点（句読点・意図した点）は1点でも残る', () {
      drawFrames(0, List.filled(10, const Vec2(0.4, 0.4)));
      at(0, InteractionKind.drawUp, const Vec2(0.4, 0.4));
      expect(model.strokes, hasLength(1));
      expect(model.strokes.single.points, hasLength(1));
    });

    test('ゆっくり描いた小さな線は軌跡が短くても残る', () {
      // 軌跡長0.008（閾値未満）だが約600ms保持している。
      drawFrames(0, line(0.3, 0.308, 19));
      at(0, InteractionKind.drawUp, const Vec2(0.308, 0.5));
      expect(model.strokes, hasLength(1));
    });
  });

  group('drawUp 以外の終了経路', () {
    test('release（追跡喪失・通信断）: 一瞬の点は破棄し、正当な線はトリムせず残す', () {
      drawFrames(0, const [Vec2(0.5, 0.5)]);
      now += frameMs;
      at(0, InteractionKind.release, const Vec2(0.5, 0.5));
      expect(model.strokes, isEmpty);
      expect(model.track(0), isNull);

      final pts = line(0.1, 0.5, 10);
      drawFrames(0, pts);
      at(0, InteractionKind.release, pts.last);
      expect(model.strokes, hasLength(1));
      expect(model.strokes.single.points, hasLength(pts.length));
    });

    test('エンジンの releaseAll 相当（drawUp→release）でも同じ判定になる', () {
      drawFrames(0, const [Vec2(0.5, 0.5)]);
      now += frameMs;
      model.applyTrackEvents({
        0: const [
          InteractionEvent(InteractionKind.drawUp, Vec2(0.5, 0.5)),
          InteractionEvent(InteractionKind.release, Vec2(0.5, 0.5)),
        ],
      });
      expect(model.strokes, isEmpty);
    });

    test('pointerExit（画面外）: 一瞬の点は破棄し、正当な線は残す', () {
      drawFrames(0, const [Vec2(0.99, 0.5)]);
      now += frameMs;
      at(0, InteractionKind.pointerExit, const Vec2(0.99, 0.5));
      expect(model.strokes, isEmpty);
      expect(model.track(0)!.pressed, isFalse);

      final pts = line(0.5, 0.99, 10);
      drawFrames(0, pts);
      at(0, InteractionKind.pointerExit, pts.last);
      expect(model.strokes, hasLength(1));
      expect(model.strokes.single.points, hasLength(pts.length));
    });

    test('モード切替（pointerMove・消しゴム）でも一瞬の点は破棄される', () {
      drawFrames(0, const [Vec2(0.2, 0.2)]);
      now += frameMs;
      at(0, InteractionKind.pointerMove, const Vec2(0.2, 0.2));
      expect(model.strokes, isEmpty);

      drawFrames(0, const [Vec2(0.8, 0.8)]);
      now += frameMs;
      // 消しゴム範囲外で eraseDown しても、微小ストロークは確定時に破棄される。
      at(0, InteractionKind.eraseDown, const Vec2(0.2, 0.2));
      expect(model.strokes, isEmpty);
    });
  });

  group('一時欠落の猶予を経て確定する場合（PR #39 との組み合わせ）', () {
    // 手が消えてから猶予（300ms）が過ぎて drawUp/release が届く。
    // 継続時間は最後に drawDown/drawMove を受けた時刻までで測る。
    const graceMs = 300;

    test('drawDown の直後に手が消え、猶予後の release でも一瞬の点は破棄される', () {
      drawFrames(0, const [Vec2(0.5, 0.5)]);
      now += graceMs;
      at(0, InteractionKind.release, const Vec2(0.5, 0.5));
      expect(model.strokes, isEmpty);
    });

    test('数フレームの極短線も、猶予後の drawUp→release で破棄される', () {
      drawFrames(0, line(0.5, 0.504, 3));
      now += graceMs;
      model.applyTrackEvents({
        0: const [
          InteractionEvent(InteractionKind.drawUp, Vec2(0.504, 0.5)),
          InteractionEvent(InteractionKind.release, Vec2(0.504, 0.5)),
        ],
      });
      expect(model.strokes, isEmpty);
    });

    test('静止した長押しの点は、猶予後の release でも残る', () {
      // 点が動かなくてもエンジンは描画中の毎フレーム drawMove を出す。
      drawFrames(0, List.filled(8, const Vec2(0.4, 0.4)));
      now += graceMs;
      at(0, InteractionKind.release, const Vec2(0.4, 0.4));
      expect(model.strokes, hasLength(1));
      expect(model.strokes.single.points, hasLength(1));
    });

    test('drawMove が続く長押しの小さな線は、猶予後の drawUp でも残る', () {
      drawFrames(0, line(0.3, 0.306, 8));
      now += graceMs;
      at(0, InteractionKind.drawUp, const Vec2(0.306, 0.5));
      expect(model.strokes, hasLength(1));
    });
  });

  group('回帰', () {
    test('消しゴム分割で生じた小さな断片は判定対象外で残る', () {
      final pts = line(0.1, 0.9, 17);
      drawFrames(0, pts);
      at(0, InteractionKind.drawUp, pts.last);
      final kept = model.strokes.single.points.length;
      expect(kept, pts.length - model.penReleaseTrimPoints);

      // 先頭1点だけを残すように消す（0.1 を残し 0.15〜0.2 付近を消す）。
      model.eraseAt(const Vec2(0.175, 0.5));
      final pieces = model.strokes.length;
      expect(pieces, greaterThanOrEqualTo(2));
      expect(model.strokes.first.points, hasLength(1));

      // 別トラックの描画・確定や同トラックの終了処理で断片が消えない。
      drawFrames(1, const [Vec2(0.5, 0.2)]);
      now += frameMs;
      at(1, InteractionKind.drawUp, const Vec2(0.5, 0.2));
      at(0, InteractionKind.release, const Vec2(0.5, 0.5));
      expect(model.strokes, hasLength(pieces));
    });

    test('2手描画: 片手の誤認識だけを破棄し、もう片手の描画中ストロークは残る', () {
      // トラック0が描画中に、トラック1で一瞬の誤認識が起きる。
      at(0, InteractionKind.drawDown, const Vec2(0.1, 0.1));
      at(1, InteractionKind.drawDown, const Vec2(0.9, 0.9));
      now += frameMs;
      model.applyTrackEvents({
        0: const [InteractionEvent(InteractionKind.drawMove, Vec2(0.2, 0.1))],
        1: const [InteractionEvent(InteractionKind.drawUp, Vec2(0.9, 0.9))],
      });
      expect(model.strokes, hasLength(1));
      expect(model.strokes.single.trackId, 0);

      for (var i = 3; i <= 9; i++) {
        now += frameMs;
        at(0, InteractionKind.drawMove, Vec2(i / 10, 0.1));
      }
      at(0, InteractionKind.drawUp, const Vec2(0.9, 0.1));
      expect(model.strokes, hasLength(1));
      expect(model.strokes.single.trackId, 0);
    });

    test('Clear All は描画中も含めて全消去し、その後の drawUp でも壊れない', () {
      drawFrames(0, line(0.1, 0.5, 10));
      model.clear();
      expect(model.strokes, isEmpty);
      now += frameMs;
      at(0, InteractionKind.drawUp, const Vec2(0.5, 0.5));
      expect(model.strokes, isEmpty);

      drawFrames(0, line(0.1, 0.5, 10));
      at(0, InteractionKind.drawUp, const Vec2(0.5, 0.5));
      expect(model.strokes, hasLength(1));
    });
  });

  group('isMicroStroke の境界', () {
    const dot = [Vec2(0.5, 0.5)];
    test('継続時間が閾値以上なら1点でも誤認識としない', () {
      expect(
        OverlayModel.isMicroStroke(
          dot,
          OverlayModel.microStrokeMaxDurationMs - 1,
        ),
        isTrue,
      );
      expect(
        OverlayModel.isMicroStroke(dot, OverlayModel.microStrokeMaxDurationMs),
        isFalse,
      );
    });

    test('点数が閾値を超えると誤認識としない', () {
      final many = List.filled(
        OverlayModel.microStrokeMaxPoints + 1,
        const Vec2(0.5, 0.5),
      );
      expect(OverlayModel.isMicroStroke(many, 0), isFalse);
    });

    test('軌跡長が閾値以上なら誤認識としない', () {
      const len = OverlayModel.microStrokeMaxPathLength;
      expect(
        OverlayModel.isMicroStroke([
          const Vec2(0.5, 0.5),
          const Vec2(0.5 + len * 0.9, 0.5),
        ], 0),
        isTrue,
      );
      expect(
        OverlayModel.isMicroStroke([
          const Vec2(0.5, 0.5),
          const Vec2(0.5 + len * 1.1, 0.5),
        ], 0),
        isFalse,
      );
    });
  });
}
