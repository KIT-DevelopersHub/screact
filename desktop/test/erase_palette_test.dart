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
    test('未選択時は新規ストロークにトラック別自動色を使う', () {
      final model = OverlayModel();
      expect(model.selectedColorSlot, isNull);
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.5, 0.5)),
      );
      // 既定トラック0の自動スロットは 0。
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

    test('同じ色を再選択すると選択解除（自動色へフォールバック）', () {
      final model = OverlayModel();
      model.selectColorSlot(1);
      model.selectColorSlot(1);
      expect(model.selectedColorSlot, isNull);
      model.applyTrack(
        0,
        const InteractionEvent(InteractionKind.drawDown, Vec2(0.4, 0.4)),
      );
      expect(model.strokes.last.colorSlot, 0);
    });
  });
}
