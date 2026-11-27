import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/core/geom.dart';
import 'package:thehack_overlay/core/interaction_engine.dart';
import 'package:thehack_overlay/core/pointer_state.dart';

/// 消しゴム（eraseAt / erase イベント）とカラーパレット（selectedColorSlot）の
/// 表示モデル挙動を検証する。実機のジェスチャー挙動は別途ハードで要確認。
void main() {
  group('OverlayModel 消しゴム', () {
    test('線の途中を消すとストロークが2本に分割される', () {
      final model = OverlayModel();
      final pts = <Vec2>[
        for (var x = 0.10; x <= 0.901; x += 0.05) Vec2(x, 0.5),
      ];
      model.strokes.add(InkStroke(pts, trackId: 0, colorSlot: 0));

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
        InkStroke([const Vec2(0.5, 0.5)], trackId: 0, colorSlot: 1),
      );
      model.eraseAt(const Vec2(0.5, 0.5));
      expect(model.strokes, isEmpty);
    });

    test('離れた点は消えない（消去半径の外）', () {
      final model = OverlayModel();
      model.strokes.add(
        InkStroke([const Vec2(0.1, 0.1)], trackId: 0, colorSlot: 0),
      );
      model.eraseAt(const Vec2(0.9, 0.9));
      expect(model.strokes.length, 1);
    });

    test('eraseDown/eraseMove イベントで近傍を消し、erasing フラグが立つ', () {
      final model = OverlayModel();
      model.strokes.add(
        InkStroke([const Vec2(0.5, 0.5)], trackId: 0, colorSlot: 0),
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

  group('OverlayModel カラーパレット', () {
    /// [trackId] で微小ストローク判定に掛からない長さの線を描いて確定する。
    void drawLine(OverlayModel model, int trackId, double y) {
      model.applyTrack(
        trackId,
        InteractionEvent(InteractionKind.drawDown, Vec2(0.1, y)),
      );
      for (var x = 0.15; x <= 0.5; x += 0.05) {
        model.applyTrack(
          trackId,
          InteractionEvent(InteractionKind.drawMove, Vec2(x, y)),
        );
      }
      model.applyTrack(
        trackId,
        InteractionEvent(InteractionKind.drawUp, Vec2(0.5, y)),
      );
    }

    test('初期の描画色は固定のスロット0（青）', () {
      final model = OverlayModel();
      expect(model.selectedColorSlot, OverlayModel.defaultInkColorSlot);
      expect(OverlayModel.defaultInkColorSlot, 0);
      // トラックの識別色が 0 以外になる trackId でも、描画色は初期色。
      model.applyTrack(
        3,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.5, 0.5)),
      );
      expect(model.track(3)!.colorSlot, isNot(0));
      expect(model.strokes.last.colorSlot, 0);
    });

    test('パレットで選んだ色が以後の新規ストロークへ適用される', () {
      final model = OverlayModel();
      model.selectColorSlot(2);
      expect(model.selectedColorSlot, 2);
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.3, 0.3)),
      );
      expect(model.strokes.last.colorSlot, 2);
    });

    // 旧仕様では同色の再選択で null（トラック別自動色）に戻していた。
    // #31 / #6 の要件「同じ色を再選択しても自動色に戻らない」に合わせて期待値を変更。
    test('同じ色を再選択しても選択は外れず、自動色へ戻らない', () {
      final model = OverlayModel();
      var notified = 0;
      model.addListener(() => notified++);
      model.selectColorSlot(1);
      model.selectColorSlot(1);
      expect(model.selectedColorSlot, 1);
      expect(notified, 1);
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.4, 0.4)),
      );
      expect(model.strokes.last.colorSlot, 1);
    });

    test('範囲外のスロットは無視して描画色を保つ', () {
      final model = OverlayModel();
      model.selectColorSlot(2);
      model.selectColorSlot(-1);
      model.selectColorSlot(OverlayModel.colorSlotCount);
      expect(model.selectedColorSlot, 2);
    });

    test('手の再認識（追跡喪失→新しい trackId）で描画色が変わらない', () {
      final model = OverlayModel();
      model.selectColorSlot(3);
      drawLine(model, 0, 0.2);
      // 追跡喪失。
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.release, Vec2(0.5, 0.2)),
      );
      expect(model.selectedColorSlot, 3);
      // 新しい trackId で再認識され、識別色は別スロットになる。
      drawLine(model, 1, 0.4);
      expect(model.track(1)!.colorSlot, isNot(3));
      expect(model.selectedColorSlot, 3);
      expect(model.strokes.map((s) => s.colorSlot), [3, 3]);
    });

    test('画角外への移動（pointerExit）と Clear All で描画色が変わらない', () {
      final model = OverlayModel();
      model.selectColorSlot(2);
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.pointerExit, Vec2(0.5, 0.5)),
      );
      expect(model.selectedColorSlot, 2);
      model.clear();
      expect(model.selectedColorSlot, 2);
      model.applyTrack(
        4,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.5, 0.5)),
      );
      expect(model.strokes.last.colorSlot, 2);
    });

    test('色を変えても描画済みの線は変色しない', () {
      final model = OverlayModel();
      drawLine(model, 0, 0.2);
      model.selectColorSlot(1);
      drawLine(model, 0, 0.4);
      model.selectColorSlot(3);
      expect(model.strokes.map((s) => s.colorSlot), [0, 1]);
    });

    test('2手は共有の描画色で描き、識別色はトラック別のまま', () {
      final model = OverlayModel();
      model.selectColorSlot(2);
      model.applyTrack(
        1,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.2, 0.2)),
      );
      model.applyTrack(
        5,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.7, 0.7)),
      );
      expect(model.strokes.map((s) => s.colorSlot), [2, 2]);
      expect(model.track(1)!.colorSlot, isNot(model.track(5)!.colorSlot));
    });
  });
}
