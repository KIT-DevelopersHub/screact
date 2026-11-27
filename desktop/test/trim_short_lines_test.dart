import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';

/// drawUp 時の末尾トリムが正当な短い線を 1 点に縮めないこと（Issue #28）と、
/// 長い線では従来どおり [OverlayModel.penReleaseTrimPoints] 点を削ることを検証する。
/// 確定時の微小ストローク破棄（Issue #5）と組み合わせた結果も確かめる。
/// 閾値は暫定値のため、実機での見え方は別途ハードで要確認。
void main() {
  late int now;
  late OverlayModel model;

  // 30fps 送信相当の1フレーム。
  const frameMs = 33;

  /// [points] を1フレームずつ描き、最後の点で drawUp する。
  void drawAndRelease(int trackId, List<Vec2> points) {
    for (var i = 0; i < points.length; i++) {
      if (i > 0) now += frameMs;
      model.applyTrack(
        trackId,
        InteractionEvent(
          i == 0 ? InteractionKind.drawDown : InteractionKind.drawMove,
          points[i],
        ),
      );
    }
    model.applyTrack(
      trackId,
      InteractionEvent(InteractionKind.drawUp, points.last),
    );
  }

  List<Vec2> line(double x0, double x1, int n, {double y = 0.5}) => [
    for (var i = 0; i < n; i++) Vec2(x0 + (x1 - x0) * i / (n - 1), y),
  ];

  /// 半径 [r] の円周を [n] 点で一周する（始点と終点が重なる）。
  List<Vec2> circle(double r, int n, {Vec2 c = const Vec2(0.5, 0.5)}) => [
    for (var i = 0; i < n; i++)
      Vec2(
        c.x + r * math.cos(2 * math.pi * i / (n - 1)),
        c.y + r * math.sin(2 * math.pi * i / (n - 1)),
      ),
  ];

  double pathLength(List<Vec2> pts) {
    var len = 0.0;
    for (var i = 1; i < pts.length; i++) {
      len += pts[i - 1].distanceTo(pts[i]);
    }
    return len;
  }

  setUp(() {
    now = 1000;
    model = OverlayModel(nowMs: () => now);
  });

  group('正当な短い線は 1 点に縮まない', () {
    test('句読点「、」のような素早い短い払い（3点）は残り、線のまま', () {
      final pts = [
        const Vec2(0.50, 0.50),
        const Vec2(0.505, 0.505),
        const Vec2(0.51, 0.512),
      ];
      // 継続時間66ms・3点でも、軌跡長が閾値以上なので微小ストロークではない。
      expect(
        pathLength(pts),
        greaterThanOrEqualTo(OverlayModel.microStrokeMaxPathLength),
      );
      drawAndRelease(0, pts);
      expect(model.strokes, hasLength(1));
      expect(model.strokes.single.points.length, greaterThanOrEqualTo(2));
    });

    test('短い横棒「ー」（4点）は残り、線のまま', () {
      final pts = line(0.4, 0.43, 4);
      drawAndRelease(0, pts);
      expect(model.strokes, hasLength(1));
      final kept = model.strokes.single.points;
      expect(kept.length, greaterThanOrEqualTo(2));
      expect(
        pathLength(kept),
        greaterThanOrEqualTo(OverlayModel.penReleaseTrimMinKeptLength),
      );
    });

    test('小さな丸「。」は残り、削られるのは軌跡の一定割合まで', () {
      for (final n in [5, 6, 8, 10]) {
        model.clear();
        final pts = circle(0.006, n);
        final total = pathLength(pts);
        drawAndRelease(0, pts);
        expect(model.strokes, hasLength(1), reason: '$n点の丸');
        final kept = model.strokes.single.points;
        expect(kept.length, greaterThanOrEqualTo(2), reason: '$n点の丸');
        expect(
          pathLength(kept),
          greaterThanOrEqualTo(
            total * (1 - OverlayModel.penReleaseTrimMaxFraction) - 1e-12,
          ),
          reason: '$n点の丸',
        );
      }
    });

    test('2点だけの短い線は削らない', () {
      final pts = [const Vec2(0.3, 0.3), const Vec2(0.32, 0.3)];
      drawAndRelease(0, pts);
      expect(model.strokes.single.points, hasLength(2));
    });

    test('ゆっくり描いた軌跡長が下限未満の小さな線は削らない', () {
      // 軌跡長0.008・約600ms。微小ストロークではなく、トリムでも縮めない。
      // 近すぎる点は間引かれるので、drawUp 直前の点数と比べる。
      final pts = line(0.3, 0.308, 19);
      model.applyTrack(0, InteractionEvent(InteractionKind.drawDown, pts[0]));
      for (final p in pts.skip(1)) {
        now += frameMs;
        model.applyTrack(0, InteractionEvent(InteractionKind.drawMove, p));
      }
      final before = model.strokes.last.points.length;
      model.applyTrack(0, InteractionEvent(InteractionKind.drawUp, pts.last));
      expect(model.strokes, hasLength(1));
      expect(model.strokes.last.points.length, before);
      expect(before, greaterThanOrEqualTo(2));
    });
  });

  group('長い線では従来どおり削る', () {
    test('一様な長い線は penReleaseTrimPoints 点を削る', () {
      final pts = line(0.1, 0.6, 20);
      drawAndRelease(0, pts);
      expect(
        model.strokes.single.points,
        hasLength(pts.length - model.penReleaseTrimPoints),
      );
    });

    test('末尾に大きなブレがある長い線も penReleaseTrimPoints 点を削る', () {
      // 本体0.3 + 末尾の大きな跳ね（全体の25%超）。残りが長いので割合で制限しない。
      final pts = [
        ...line(0.1, 0.4, 12),
        const Vec2(0.45, 0.55),
        const Vec2(0.50, 0.62),
        const Vec2(0.56, 0.70),
      ];
      drawAndRelease(0, pts);
      final kept = model.strokes.single.points;
      expect(kept, hasLength(pts.length - model.penReleaseTrimPoints));
      expect(kept.last.distanceTo(const Vec2(0.4, 0.5)), lessThan(1e-9));
    });

    test('penReleaseTrimPoints = 0 なら削らない', () {
      model.penReleaseTrimPoints = 0;
      final pts = line(0.1, 0.6, 20);
      drawAndRelease(0, pts);
      expect(model.strokes.single.points, hasLength(pts.length));
    });
  });

  group('微小ストローク破棄との組み合わせ', () {
    test('一瞬の点や極短線は従来どおり破棄され、正当な短い線は残る', () {
      // 誤認識: 1点のタップと、軌跡長0.006の極短線。
      drawAndRelease(0, const [Vec2(0.2, 0.2)]);
      now += frameMs;
      drawAndRelease(0, line(0.5, 0.506, 4));
      expect(model.strokes, isEmpty);

      // 正当: 句読点・短い横棒・小さな丸。
      now += frameMs;
      drawAndRelease(0, [
        const Vec2(0.30, 0.30),
        const Vec2(0.305, 0.305),
        const Vec2(0.31, 0.312),
      ]);
      now += frameMs;
      drawAndRelease(0, line(0.4, 0.43, 4));
      now += frameMs;
      drawAndRelease(0, circle(0.006, 6, c: const Vec2(0.7, 0.7)));
      expect(model.strokes, hasLength(3));
      for (final s in model.strokes) {
        expect(s.points.length, greaterThanOrEqualTo(2));
      }
    });
  });

  group('penReleaseTrimCount の境界', () {
    test('点数が下限以下・最大点数0なら削らない', () {
      expect(OverlayModel.penReleaseTrimCount(const [Vec2(0.5, 0.5)], 3), 0);
      expect(OverlayModel.penReleaseTrimCount(line(0.1, 0.2, 2), 3), 0);
      expect(OverlayModel.penReleaseTrimCount(line(0.1, 0.6, 20), 0), 0);
    });

    test('残す点数の下限を守る', () {
      // 長い3点の線: 割合・長さの制限に掛からず、2点残すまで削る。
      expect(OverlayModel.penReleaseTrimCount(line(0.1, 0.9, 3), 3), 1);
    });

    test('短い線は削る長さが割合の上限を超えない', () {
      // 0.05 を 10 区間: 1区間=10%、2区間=20%、3区間=30%。
      expect(OverlayModel.penReleaseTrimCount(line(0.1, 0.15, 11), 3), 2);
    });
  });
}
