import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';

/// 消しゴム（eraseAt / erase イベント）とペン色サイクル（penColor / cyclePenColor）
/// の表示モデル挙動を検証する。実機のジェスチャー挙動は別途ハードで要確認。
void main() {
  group('OverlayModel 消しゴム', () {
    test('線の途中を消すとストロークが2本に分割される', () {
      final model = OverlayModel();
      final pts = <Vec2>[
        for (var x = 0.10; x <= 0.901; x += 0.05) Vec2(x, 0.5),
      ];
      model.strokes.add(InkStroke(pts, trackId: 0));

      model.eraseAt(const Vec2(0.5, 0.5));

      expect(model.strokes.length, 2, reason: '中央を消して前後に分かれる');
      for (final s in model.strokes) {
        for (final p in s.points) {
          expect(
            p.distanceTo(const Vec2(0.5, 0.5)),
            greaterThan(OverlayModel.eraserRadius),
          );
        }
      }
    });

    test('消去半径内だけの小さなストロークは丸ごと消える', () {
      final model = OverlayModel();
      model.strokes.add(
        InkStroke([const Vec2(0.5, 0.5)], trackId: 0),
      );
      model.eraseAt(const Vec2(0.5, 0.5));
      expect(model.strokes, isEmpty);
    });

    test('離れた点は消えない（消去半径の外）', () {
      final model = OverlayModel();
      model.strokes.add(
        InkStroke([const Vec2(0.1, 0.1)], trackId: 0),
      );
      model.eraseAt(const Vec2(0.9, 0.9));
      expect(model.strokes.length, 1);
    });

    test('eraseDown/eraseMove イベントで近傍を消し、erasing フラグが立つ', () {
      final model = OverlayModel();
      model.strokes.add(
        InkStroke([const Vec2(0.5, 0.5)], trackId: 0),
      );
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.eraseDown, Vec2(0.5, 0.5)),
      );
      expect(model.strokes, isEmpty);
      expect(model.track(0)!.erasing, isTrue);

      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.eraseUp, Vec2(0.5, 0.5)),
      );
      expect(model.track(0)!.erasing, isFalse);
    });
  });

  group('OverlayModel ペン色サイクル', () {
    // penCycle = [赤, 黄, 緑, 青]。初期は青（末尾）。
    test('初期のペン色は青', () {
      final model = OverlayModel();
      expect(model.penColor, OverlayModel.penCycle[3]); // 青
      expect(model.penColor, OverlayModel.defaultPenColor);
    });

    test('クリックで 赤 → 黄 → 緑 → 青 → 赤 と循環する', () {
      final model = OverlayModel();
      model.cyclePenColor();
      expect(model.penColor, OverlayModel.penCycle[0]); // 赤
      model.cyclePenColor();
      expect(model.penColor, OverlayModel.penCycle[1]); // 黄
      model.cyclePenColor();
      expect(model.penColor, OverlayModel.penCycle[2]); // 緑
      model.cyclePenColor();
      expect(model.penColor, OverlayModel.penCycle[3]); // 青
      model.cyclePenColor();
      expect(model.penColor, OverlayModel.penCycle[0]); // 赤（一周して戻る）
    });

    test('新規ストロークは現在のペン色で描かれる', () {
      final model = OverlayModel();
      model.cyclePenColor(); // 青 → 赤
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.3, 0.3)),
      );
      expect(model.strokes.last.color, OverlayModel.penCycle[0]); // 赤
    });

    test('未操作なら新規ストロークは初期色（青）で描かれる', () {
      final model = OverlayModel();
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.5, 0.5)),
      );
      expect(model.strokes.last.color, OverlayModel.defaultPenColor); // 青
    });
  });

  group('OverlayModel 色丸ヒットテスト（ピンチ/くっつき）', () {
    // 右下に色丸の当たり判定を置く。中心 (0.85, 0.85)。
    const rect = Rect.fromLTWH(0.80, 0.80, 0.10, 0.10);

    test('色丸の上での drawDown は描画せず色送りだけ行う', () {
      final model = OverlayModel()..colorButtonRect = rect;
      final before = model.penColor;
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.85, 0.85)),
      );
      expect(model.strokes, isEmpty, reason: '色丸の上では線を引かない');
      expect(model.penColor, isNot(before), reason: '色が1つ進む');
      expect(model.track(0)!.cyclingColor, isTrue);
    });

    test('色丸の上での pressDown（ピンチ）も色送りになる', () {
      final model = OverlayModel()..colorButtonRect = rect;
      final before = model.penColor;
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.pressDown, Vec2(0.86, 0.84)),
      );
      expect(model.penColor, isNot(before));
      expect(model.track(0)!.pressed, isFalse, reason: 'クリック押下扱いにしない');
    });

    test('色丸の外での drawDown は従来どおり描画する', () {
      final model = OverlayModel()..colorButtonRect = rect;
      final before = model.penColor;
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.2, 0.2)),
      );
      expect(model.strokes, hasLength(1));
      expect(model.penColor, before, reason: '色丸の外では色は変わらない');
    });

    test('色送り中の drawMove は点を増やさない（描画に化けない）', () {
      final model = OverlayModel()..colorButtonRect = rect;
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.85, 0.85)),
      );
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawMove, Vec2(0.86, 0.86)),
      );
      expect(model.strokes, isEmpty);
    });

    test('連続ピンチはデバウンスで1回だけ色送り（チャタリング防止）', () {
      final model = OverlayModel()..colorButtonRect = rect;
      final before = model.penColor;
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.pressDown, Vec2(0.85, 0.85)),
      );
      final afterFirst = model.penColor;
      // すぐ開放して即再ピンチ（デバウンス窓内）。
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.pressUp, Vec2(0.85, 0.85)),
      );
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.pressDown, Vec2(0.85, 0.85)),
      );
      expect(model.penColor, isNot(before));
      expect(model.penColor, afterFirst, reason: '窓内の2回目は無視される');
    });
  });
}
