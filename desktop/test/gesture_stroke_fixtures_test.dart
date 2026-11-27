import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/mock_hand.dart';
import 'package:thehack_overlay/core/multi_hand_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';
import 'package:thehack_overlay/protocol/input_frame.dart';
import 'package:thehack_overlay/protocol/messages.dart';

import 'multi_hand_test.dart' show multiHandFrame;

/// 21点の手の動きから、ジェスチャー判定（GestureRecognizer / InteractionEngine /
/// MultiHandEngine）と OverlayModel を通して、誤認識と正常な描画を再現する
/// （Issue #29 / 親 #5）。誤認識は確定後に残らず、正常な描画は残ることを確かめる。
///
/// 平滑化（One-Euro）は既定どおり有効にし、実際の操作に近い経路で見る。
/// 手は 30fps（33ms 間隔）で届く想定。画面座標 0..1 は位置合わせ後の
/// カメラ座標 0.1..0.9 に対応する（[MockHand.markers]）。
///
/// 今の実装で期待どおりにならないケースは skip に理由を書いて残す。
/// skip の一覧は閾値調整（5-05）の入力にする。
void main() {
  const frameMs = 33;

  /// 画面座標 → カメラ正規化座標（[MockHand.markers] の枠に合わせる）。
  Vec2 cam(Vec2 s) => Vec2(0.1 + 0.8 * s.x, 0.1 + 0.8 * s.y);

  /// 人差し指先端が画面の [s] にある手。
  /// [together] で人差し指と中指をくっつける（＝ペン）。
  /// [gap] を与えると、中指先端を人差し指先端の右へ [gap]（カメラ正規化）だけ
  /// 離す（＝ペンを解除する途中の、指が開きかけた手）。
  HandFrame hand(int frameId, Vec2 s, {bool together = false, double? gap}) {
    final tip = cam(s);
    final f = MockHand.at(
      frameId: frameId,
      tip: tip,
      pinch: false,
      together: together || gap != null,
    );
    if (gap == null) return f;
    final lm = f.landmarks.toList();
    lm[HandFrame.middleTip] = Landmark(tip.x + gap, tip.y, 0);
    return HandFrame(
      frameId: f.frameId,
      capturedAtMonotonicMs: f.capturedAtMonotonicMs,
      detected: true,
      handedness: f.handedness,
      landmarks: lm,
    );
  }

  /// [a] から [b] まで [n] 点（両端を含む）。
  List<Vec2> path(Vec2 a, Vec2 b, int n) => [
    for (var i = 0; i < n; i++) a + (b - a) * (i / (n - 1)),
  ];

  double maxDeviationY(List<Vec2> points, double y) =>
      points.map((p) => (p.y - y).abs()).reduce((a, b) => a > b ? a : b);

  group('InteractionEngine → OverlayModel', () {
    late InteractionEngine engine;
    late OverlayModel model;
    late int frameId;

    /// 1フレーム進めて手をエンジンへ流し、出たイベントをオーバーレイへ反映する。
    /// オーバーレイの時計はフレームの撮影時刻にそろえる。
    List<InteractionKind> feed(HandFrame Function(int id) make) {
      frameId++;
      final events = engine.onFrame(make(frameId));
      for (final e in events) {
        model.apply(e);
      }
      return events.map((e) => e.kind).toList();
    }

    /// ペンを作らず人差し指で [points] をなぞる（ポインタ移動）。
    void hover(List<Vec2> points) {
      for (final p in points) {
        feed((id) => hand(id, p));
      }
    }

    /// ペンの形で [points] をなぞる。最初のフレームで drawDown が出ることを確かめる。
    void pen(List<Vec2> points) {
      for (var i = 0; i < points.length; i++) {
        final kinds = feed((id) => hand(id, points[i], together: true));
        if (i == 0) expect(kinds, contains(InteractionKind.drawDown));
      }
    }

    /// 指を離してペンを解除する（drawUp が出ることを確かめる）。
    void lift(Vec2 at) {
      expect(feed((id) => hand(id, at)), contains(InteractionKind.drawUp));
    }

    /// 描画中ストロークの点数（確定前）。
    int activePoints() => model.strokes.last.points.length;

    setUp(() {
      frameId = 30;
      engine = InteractionEngine();
      expect(engine.calibrate(MockHand.markers()), isTrue);
      model = OverlayModel(nowMs: () => frameId * frameMs);
    });

    group('誤認識は確定後に残らない', () {
      test('止まった手でペンの形が1フレームだけ現れても、点は残らない', () {
        const at = Vec2(0.4, 0.5);
        hover(List.filled(5, at));
        pen(const [at]);
        expect(model.strokes, hasLength(1), reason: '描画中は即時表示する');
        lift(at);
        hover(List.filled(3, at));
        expect(model.strokes, isEmpty);
      });

      test('止まった手でペンの形が2フレームだけ現れても、点は残らない', () {
        const at = Vec2(0.4, 0.5);
        hover(List.filled(5, at));
        pen(List.filled(2, at));
        lift(at);
        expect(model.strokes, isEmpty);
      });

      test('ゆっくり動く手でペンの形が2フレームだけ現れても、線は残らない', () {
        // 1フレーム 0.003（画面幅の0.3%）でゆっくり右へ動かす。
        final route = path(const Vec2(0.3, 0.5), const Vec2(0.33, 0.5), 11);
        hover(route.sublist(0, 5));
        pen(route.sublist(5, 7));
        lift(route[7]);
        hover(route.sublist(8));
        expect(model.strokes, isEmpty);
      });

      test(
        '速く動く手でペンの形が2フレームだけ現れても、線は残らない',
        () {
          // 1フレーム 0.02（画面幅の2%）で右へ動かす途中に、2フレームだけペンの形。
          final route = path(const Vec2(0.2, 0.5), const Vec2(0.38, 0.5), 10);
          hover(route.sublist(0, 5));
          pen(route.sublist(5, 7));
          lift(route[7]);
          hover(route.sublist(8));
          expect(model.strokes, isEmpty);
        },
        skip:
            '今の実装では残る。2フレーム（継続 33ms）でも、手が速く動いていると'
            '軌跡長が microStrokeMaxPathLength（0.01）を超え、誤認識と判定されない。'
            '2点の線は末尾トリムの対象外のため、そのまま残る（閾値調整 5-05 の入力）。',
      );

      test('ペンを解除するときの指が開きながらのブレは、確定後の線に残らない', () {
        // 左から右へ横線を引き、最後に指を開きながら手が下へ流れる。
        final route = path(const Vec2(0.2, 0.5), const Vec2(0.58, 0.5), 20);
        hover(List.filled(5, route.first));
        pen(route);
        // 中指が少しずつ離れる。ヒステリシス内（OFF 比率未満）なのでペンのまま。
        for (var k = 1; k <= 4; k++) {
          final kinds = feed(
            (id) => hand(id, Vec2(0.58, 0.5 + 0.02 * k), gap: 0.02 + 0.012 * k),
          );
          expect(kinds, [InteractionKind.drawMove], reason: 'ブレもまだ描画中');
        }
        // 指が十分に開いてペン解除。
        expect(
          feed((id) => hand(id, const Vec2(0.58, 0.6), gap: 0.1)),
          contains(InteractionKind.drawUp),
        );
        expect(model.strokes, hasLength(1), reason: '線そのものは残る');
        final points = model.strokes.single.points;
        // ブレは下へ 0.08 流れたが、確定後の線はほぼ水平のまま。
        expect(maxDeviationY(points, 0.5), lessThan(0.01));
        expect(points.last.x - points.first.x, greaterThan(0.25));
      });

      test('ペンの形が出た直後に追跡を失っても、点は残らない', () {
        const at = Vec2(0.4, 0.5);
        hover(List.filled(5, at));
        pen(const [at]);
        frameId++;
        final events = engine.onFrame(
          HandFrame(
            frameId: frameId,
            capturedAtMonotonicMs: frameId * frameMs,
            detected: false,
          ),
        );
        expect(
          events.map((e) => e.kind),
          containsAll([InteractionKind.drawUp, InteractionKind.release]),
        );
        events.forEach(model.apply);
        expect(model.strokes, isEmpty);
      });

      test('画面の端でペンの形が出た直後に画面外へ出ても、点は残らない', () {
        hover(List.filled(5, const Vec2(0.97, 0.5)));
        pen(const [Vec2(0.98, 0.5)]);
        expect(
          feed((id) => hand(id, const Vec2(1.1, 0.5), together: true)),
          contains(InteractionKind.pointerExit),
        );
        expect(model.strokes, isEmpty);
      });
    });

    group('正常な描画は確定後に残る', () {
      test('横線は残り、末尾だけがトリムされる', () {
        final route = path(const Vec2(0.2, 0.4), const Vec2(0.7, 0.4), 20);
        hover(List.filled(5, route.first));
        pen(route);
        final before = activePoints();
        lift(route.last);
        expect(model.strokes, hasLength(1));
        expect(
          model.strokes.single.points,
          hasLength(before - model.penReleaseTrimPoints),
        );
      });

      test('素早い短線（4フレーム）は残り、線のまま', () {
        // 1フレーム 0.01 で 0.03 だけ横へ払う。
        final route = path(const Vec2(0.4, 0.5), const Vec2(0.43, 0.5), 4);
        hover(List.filled(5, route.first));
        pen(route);
        lift(route.last);
        expect(model.strokes, hasLength(1));
        expect(model.strokes.single.points.length, greaterThanOrEqualTo(2));
      });

      test('句読点「、」のような短い払い（6フレーム）は残る', () {
        // 右下へ約 0.02 だけ、約165ms かけて短く払う。
        final route = path(const Vec2(0.5, 0.5), const Vec2(0.514, 0.514), 6);
        hover(List.filled(5, route.first));
        pen(route);
        lift(route.last);
        expect(model.strokes, hasLength(1));
        expect(model.strokes.single.points.length, greaterThanOrEqualTo(2));
      });

      test(
        '句読点「、」のような素早い短い払い（5フレーム）は残る',
        () {
          // 右下へ約 0.02 だけ、約132ms で短く払う。
          final route = path(const Vec2(0.5, 0.5), const Vec2(0.514, 0.514), 5);
          hover(List.filled(5, route.first));
          pen(route);
          lift(route.last);
          expect(model.strokes, hasLength(1));
          expect(model.strokes.single.points.length, greaterThanOrEqualTo(2));
        },
        skip:
            '今の実装では消える。平滑化（One-Euro）の遅れで画面上の軌跡長が'
            '手の動き（約0.02）の半分以下（約0.0085）に縮み、継続 132ms・4点と'
            'あわせて誤認識（microStrokeMaxPathLength 0.01 未満）と判定される'
            '（閾値調整 5-05 の入力）。',
      );

      test('長押しで打った点は1点でも残る', () {
        const at = Vec2(0.6, 0.6);
        hover(List.filled(5, at));
        pen(List.filled(8, at)); // 約264ms 保持する。
        lift(at);
        expect(model.strokes, hasLength(1));
        expect(model.strokes.single.points, hasLength(1));
      });

      test('ゆっくり引いた線は残る', () {
        // 1フレーム 0.001 で 40 フレーム（約1.3秒）かけて 0.04 だけ引く。
        final route = path(const Vec2(0.3, 0.3), const Vec2(0.34, 0.3), 41);
        hover(List.filled(5, route.first));
        pen(route);
        lift(route.last);
        expect(model.strokes, hasLength(1));
        final points = model.strokes.single.points;
        expect(points.length, greaterThanOrEqualTo(2));
        expect(points.last.x - points.first.x, greaterThan(0.01));
      });

      test('小さな文字「二」（短い横線2本）は2本とも残る', () {
        final upper = path(const Vec2(0.45, 0.45), const Vec2(0.48, 0.45), 6);
        final lower = path(const Vec2(0.44, 0.49), const Vec2(0.49, 0.49), 7);
        hover(List.filled(5, upper.first));
        pen(upper);
        lift(upper.last);
        hover(path(upper.last, lower.first, 4));
        pen(lower);
        lift(lower.last);
        expect(model.strokes, hasLength(2));
        for (final s in model.strokes) {
          expect(s.points.length, greaterThanOrEqualTo(2));
        }
        // 上の横線が先、下の横線が後に確定している。
        expect(
          model.strokes[1].points.last.y,
          greaterThan(model.strokes[0].points.last.y + 0.02),
        );
      });

      test('線を引いたまま画面外へ出ても、画面内の線は残る', () {
        final route = path(const Vec2(0.7, 0.5), const Vec2(0.98, 0.5), 15);
        hover(List.filled(5, route.first));
        pen(route);
        final before = activePoints();
        expect(
          feed((id) => hand(id, const Vec2(1.1, 0.5), together: true)),
          contains(InteractionKind.pointerExit),
        );
        // エンジンは画面外へ出るとき drawUp を出してから pointerExit を出すため、
        // ペン解除と同じく末尾だけがトリムされる。
        expect(model.strokes, hasLength(1));
        expect(
          model.strokes.single.points,
          hasLength(before - model.penReleaseTrimPoints),
        );
      });
    });
  });

  group('MultiHandEngine（一時欠落の猶予つき）→ OverlayModel', () {
    const trackId = 7;
    const graceMs = MultiHandEngine.defaultTrackLossGraceMs;
    late int clock;
    late int frameId;
    late MultiHandEngine engine;
    late OverlayModel model;

    Map<String, dynamic> track(Vec2 s, {bool together = false}) {
      final f = hand(0, s, together: together);
      return {
        'trackId': trackId,
        'landmarks': [
          for (final l in f.landmarks) [l.x, l.y, l.z],
        ],
      };
    }

    Map<int, List<InteractionEvent>> step(List<Map<String, dynamic>> hands) {
      clock += frameMs;
      frameId++;
      final out =
          engine.onInputFrame(
            InputFrame.parse(
              multiHandFrame(frameId, hands, capturedAtMs: clock),
            )!,
          )!;
      model.applyTrackEvents(out);
      return out;
    }

    /// 手が消えたフレームを猶予が切れるまで流す。
    void loseUntilExpired() {
      var elapsed = 0;
      while (elapsed < graceMs) {
        step(const []);
        elapsed += frameMs;
      }
      expect(engine.lostTrackIds, isEmpty, reason: '猶予切れで確定済み');
    }

    setUp(() {
      clock = 1000;
      frameId = 0;
      engine = MultiHandEngine(clock: () => clock);
      expect(engine.calibrate(MockHand.markers()), isTrue);
      model = OverlayModel(nowMs: () => clock);
    });

    test('ペンの形が2フレームだけ出て手を見失っても、猶予後に点は残らない', () {
      const at = Vec2(0.4, 0.5);
      for (var i = 0; i < 5; i++) {
        step([track(at)]);
      }
      step([track(at, together: true)]);
      step([track(at, together: true)]);
      expect(model.strokes, hasLength(1), reason: '描画中は即時表示する');
      loseUntilExpired();
      expect(model.strokes, isEmpty);
    });

    test('線を引いている途中で手を見失っても、猶予後に線は残る', () {
      final route = path(const Vec2(0.2, 0.5), const Vec2(0.6, 0.5), 20);
      for (var i = 0; i < 5; i++) {
        step([track(route.first)]);
      }
      for (final p in route) {
        step([track(p, together: true)]);
      }
      loseUntilExpired();
      expect(model.strokes, hasLength(1));
      final points = model.strokes.single.points;
      expect(points.length, greaterThanOrEqualTo(10));
      expect(points.last.x - points.first.x, greaterThan(0.25));
    });
  });
}
